defmodule ItsmBackend.Surreal.ExactParametersTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Jobs.SurrealStore, as: JobsStore
  alias ItsmBackend.Chats.SurrealStore, as: ChatsStore
  alias ItsmBackend.Surreal

  defp result!(statement, params) do
    assert {:ok, [%{"status" => "OK", "result" => result}]} = Surreal.query(statement, params)
    result
  end

  test "actual RPC preserves punctuation, IPv6, date-like text, JSON primitives and exact results" do
    sample = %{
      "summary" => "VPN: users cannot connect",
      "address" => "fd00:1234::1",
      "date_text" => "2026-10-22T07:13:11.123456Z",
      "n" => 3,
      "f" => 1.5,
      "null" => nil,
      "bool" => true,
      "list" => ["job:abc:1:completed", "Ünicode: ☃"]
    }

    assert [^sample, "string", "string", "string", "int", "float"] =
             result!(
               "RETURN [$value, type::of($value.summary), type::of($value.address), type::of($value.date_text), type::of($value.n), type::of($value.f)];",
               %{"value" => sample}
             )
  end

  test "trusted datetime fields and list elements retain database types without guessing adjacent text" do
    at = "2026-10-22T07:13:11.123456Z"

    record = %{
      "created_at" => Surreal.datetime(at),
      "due_text" => at,
      "items" => [Surreal.datetime(at), "a:b", %{"at" => Surreal.datetime(at)}]
    }

    assert ["datetime", "string", "datetime", "a:b", "datetime"] =
             result!(
               "RETURN [type::of($data.created_at), type::of($data.due_text), type::of($data.items[0]), $data.items[1], type::of($data.items[2].at)];",
               %{"data" => record}
             )
  end

  test "job writes and approval compare-and-set preserve the full approved target" do
    {:ok, job} =
      Job.new(%{
        user_id: "exact-text-user",
        conversation_id: "chat:exact:history",
        message: "VPN: users cannot connect"
      })

    proposal = %{
      "tool" => "ticket_create",
      "approval_id" => "approval-exact",
      "arguments" => %{"summary" => "VPN: users cannot connect", "project_key" => "SUP"}
    }

    waiting = %{job | status: "waiting_approval", attempts: 1, proposed_tool: proposal}
    assert {:ok, stored} = JobsStore.create(waiting)
    assert stored.message == job.message
    assert stored.conversation_id == job.conversation_id
    assert stored.proposed_tool == proposal

    changed = %{
      stored
      | proposed_tool: put_in(proposal, ["arguments", "summary"], "VPN: different target")
    }

    assert {:ok, nil} =
             JobsStore.continue_if_waiting_approval(changed, %{stored | status: "completed"})

    done = %{
      stored
      | status: "completed",
        result: %{"answer" => "Result: verified exact text", "address" => "fd00:1234::1"}
    }

    assert {:ok, finished} = JobsStore.complete_if_waiting_approval(done)
    assert finished.result == done.result
    assert finished.proposed_tool == proposal

    assert [%{"status" => "OK", "result" => [true, "int"]}] =
             elem(
               Surreal.query(
                 "RETURN [(SELECT VALUE type::is_datetime(created_at) FROM ONLY type::record('job', $id)), (SELECT VALUE type::of(attempts) FROM ONLY type::record('job', $id))];",
                 %{"id" => job.id}
               ),
               1
             )
  end

  test "chat titles roundtrip without changing timestamp ordering types" do
    id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    record = %{
      "chat_id" => id,
      "user_id" => "exact-user",
      "title" => "VPN: users cannot connect",
      "created_at" => now,
      "updated_at" => now,
      "archived_at" => nil
    }

    assert {:ok, created} = ChatsStore.create(record)
    assert created["title"] == record["title"]

    assert [true, true] =
             result!(
               "RETURN [(SELECT VALUE type::is_datetime(created_at) FROM ONLY type::record('chat', $id)), (SELECT VALUE type::is_datetime(updated_at) FROM ONLY type::record('chat', $id))];",
               %{"id" => id}
             )

    assert {:ok, archived} = ChatsStore.archive(id, now)
    assert archived["title"] == record["title"]
  end

  test "invalid bindings fail before any mutation statement can run" do
    assert {:ok, _} =
             Surreal.query("DEFINE TABLE IF NOT EXISTS invalid_binding_probe SCHEMALESS;")

    nested = Enum.reduce(1..66, 0, fn _, item -> [item] end)

    for value <- [
          Surreal.datetime("invalid date"),
          9_223_372_036_854_775_808,
          nested,
          %{bad_key: "value"}
        ] do
      id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      statement =
        "CREATE ONLY type::record('invalid_binding_probe', $id) SET observed = true; RETURN $value;"

      assert {:error, {:invalid_surreal_parameters, _}} =
               Surreal.query(statement, %{"id" => id, "value" => value})

      assert nil ==
               result!("SELECT * FROM ONLY type::record('invalid_binding_probe', $id);", %{
                 "id" => id
               })
    end
  end

  test "storage chat aliases resolve explicitly and retain history, archive and owner checks" do
    owner = %{"user_id" => "exact-alias-owner", "role" => "user"}
    other = %{"user_id" => "another-owner", "role" => "user"}
    assert {:ok, chat} = ItsmBackend.Chats.create(owner, %{"title" => "Alias: exact chat"})

    assert {:ok, job} =
             Job.new(%{
               user_id: owner["user_id"],
               conversation_id: chat["chat_id"],
               message: "Alias: retain this message"
             })

    assert {:ok, _stored} = JobsStore.create(job)

    assert {:ok, resolved} = ItsmBackend.Chats.get_authorized(owner, chat["id"])
    assert resolved["chat_id"] == chat["chat_id"]
    assert {:error, :forbidden} = ItsmBackend.Chats.get_authorized(other, chat["id"])
    assert {:ok, history} = ItsmBackend.Chats.history(owner, chat["id"])
    assert Enum.any?(history, &(&1["job_id"] == job.id and &1["content"] == job.message))
    assert {:ok, archived} = ItsmBackend.Chats.archive(owner, chat["id"])
    assert archived["chat_id"] == chat["chat_id"]
    assert is_binary(archived["archived_at"])
  end

  test "numeric-looking chat record aliases retain their quoted string identity" do
    id =
      :crypto.strong_rand_bytes(32)
      |> :binary.bin_to_list()
      |> Enum.map_join(&Integer.to_string(rem(&1, 10)))

    now = DateTime.to_iso8601(DateTime.utc_now())

    assert {:ok, chat} =
             ChatsStore.create(%{
               "chat_id" => id,
               "user_id" => "exact-numeric-owner",
               "title" => "Numeric identity",
               "created_at" => now,
               "updated_at" => now,
               "archived_at" => nil
             })

    assert {:ok, fetched} = ChatsStore.get(chat["id"])
    assert fetched["chat_id"] == id
  end

  test "exact lookup keeps the configured database index usable" do
    plan =
      result!("SELECT * FROM auth_session WHERE token_hash = $hash EXPLAIN;", %{
        "hash" => String.duplicate("0", 64)
      })

    encoded = Jason.encode!(plan)
    assert encoded =~ "IndexScan"
    assert encoded =~ "auth_session_token_hash"
  end

  test "local variable shadowing and original multi-statement result ordering remain intact" do
    assert {:ok, [%{"result" => 7}, %{"result" => "Note: preserved"}]} =
             Surreal.query("RETURN { LET $value = 7; RETURN $value; }; RETURN $value;", %{
               "value" => "Note: preserved"
             })
  end
end
