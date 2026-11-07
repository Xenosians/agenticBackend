defmodule ItsmBackend.Extensions.SurrealStoreTest do
  @moduledoc """
  Durable extension records and audit events (Stage 4.2 storage boundary).

  Create is an idempotent identity write, transition applies one guarded
  status change with its audit event atomically, and events replay in
  creation order.
  """
  use ExUnit.Case, async: false

  alias ItsmBackend.Extensions.SurrealStore

  defp ids, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp record(user_id \\ ids()) do
    record_id = ids()

    %{
      "record_id" => record_id,
      "user_id" => user_id,
      "kind" => "lua_plugin",
      "extension_id" => "lua-row-transform",
      "record_version" => 1,
      "extension_version" => "1.0.0",
      "status" => "pending",
      "source_type" => "lua_source",
      "source_sha256" => String.duplicate("c", 64),
      "manifest_sha256" => String.duplicate("d", 64),
      "manifest" => %{"schema" => "extension-manifest.v1"},
      "created_at" => now(),
      "updated_at" => now()
    }
  end

  defp event(record, action, from, to) do
    %{
      "event_id" => ids(),
      "user_id" => record["user_id"],
      "record_id" => record["record_id"],
      "action" => action,
      "from_status" => from,
      "to_status" => to,
      "created_at" => now()
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  test "create, get, list and events round-trip" do
    rec = record()
    assert {:ok, created} = SurrealStore.create(rec, event(rec, "register", nil, "pending"))
    assert created["record_id"] == rec["record_id"]
    assert created["status"] == "pending"

    assert {:ok, fetched} = SurrealStore.get(rec["record_id"])
    assert fetched["user_id"] == rec["user_id"]

    assert {:ok, [listed]} = SurrealStore.list_for_user(rec["user_id"], 10)
    assert listed["record_id"] == rec["record_id"]

    assert {:ok, [first]} = SurrealStore.list_events(rec["user_id"], rec["record_id"], 10)
    assert first["action"] == "register"
    assert first["to_status"] == "pending"
  end

  test "a guarded transition writes its audit event once" do
    rec = record()
    {:ok, _} = SurrealStore.create(rec, event(rec, "register", nil, "pending"))

    ev = event(rec, "review", "pending", "reviewed")

    assert {:ok, updated} =
             SurrealStore.transition(
               rec["user_id"],
               rec["record_id"],
               ["pending"],
               "review",
               "reviewed",
               ev
             )

    assert updated["status"] == "reviewed"
    assert is_binary(updated["reviewed_at"])

    assert {:ok, events} = SurrealStore.list_events(rec["user_id"], rec["record_id"], 10)
    assert Enum.map(events, & &1["action"]) == ["register", "review"]
  end

  test "a rejected transition reports the current status without an event" do
    rec = record()
    {:ok, _} = SurrealStore.create(rec, event(rec, "register", nil, "pending"))

    ev = event(rec, "activate", "pending", "active")

    assert {:error, {:transition_not_allowed, "pending"}} =
             SurrealStore.transition(
               rec["user_id"],
               rec["record_id"],
               ["reviewed"],
               "activate",
               "active",
               ev
             )

    assert {:ok, events} = SurrealStore.list_events(rec["user_id"], rec["record_id"], 10)
    assert Enum.map(events, & &1["action"]) == ["register"]
  end
end
