defmodule ItsmBackend.Workflows.SurrealStore do
  @moduledoc false

  alias ItsmBackend.Surreal

  @table "workflow"
  @run_table "workflow_run"

  def create(workflow) do
    statement = "CREATE ONLY type::record($table, $id) CONTENT $workflow RETURN AFTER;"

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @table,
             "id" => workflow["workflow_id"],
             "workflow" =>
               Surreal.datetime_fields(workflow, ~w(created_at updated_at archived_at))
           }),
         {:ok, record} when is_map(record) <- single(results),
         stored = normalize(record),
         true <-
           matches_fields?(
             stored,
             Map.take(
               workflow,
               ~w(workflow_id user_id version name definition definition_sha256 layout)
             )
           ) do
      {:ok, stored}
    else
      {:ok, nil} -> {:error, :workflow_not_created}
      false -> {:error, :workflow_write_outcome_unknown}
      error -> error
    end
  end

  def get(workflow_id) do
    statement = "SELECT * FROM ONLY type::record($table, $id);"

    with {:ok, results} <- Surreal.query(statement, %{"table" => @table, "id" => workflow_id}),
         {:ok, record} <- single(results) do
      {:ok, record && normalize(record)}
    end
  end

  def list_for_user(user_id, limit) do
    statement = """
    SELECT * FROM workflow
    WHERE user_id = $user_id AND archived_at = $archived_at
    ORDER BY updated_at DESC
    LIMIT $limit;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "user_id" => user_id,
             "archived_at" => nil,
             "limit" => limit
           }),
         {:ok, rows} <- rows(results) do
      {:ok,
       Enum.map(rows || [], fn row ->
         row
         |> normalize()
         |> Map.take(~w(workflow_id name version definition_sha256 updated_at))
       end)}
    end
  end

  @doc """
  Writes a new version only while the stored version is still `base`; a
  concurrent save leaves zero rows updated and becomes a version conflict.
  """
  def update_version(user_id, workflow_id, base, input, now) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET name = $name, definition = $definition, definition_sha256 = $digest,
        layout = $layout, version = version + 1, updated_at = $now
    WHERE user_id = $owner AND version = $base AND archived_at = $archived_at
    RETURN AFTER;
    """

    params = %{
      "table" => @table,
      "id" => workflow_id,
      "owner" => user_id,
      "name" => input["name"],
      "definition" => input["definition"],
      "digest" => input["definition_sha256"],
      "layout" => input["layout"],
      "base" => base,
      "archived_at" => nil,
      "now" => Surreal.datetime(now)
    }

    with {:ok, results} <- Surreal.query(statement, params),
         {:ok, record} <- single(results) do
      cond do
        is_nil(record) ->
          {:error, :version_conflict}

        matches_fields?(
          record,
          Map.merge(input, %{
            "workflow_id" => workflow_id,
            "user_id" => user_id,
            "version" => base + 1
          })
        ) ->
          {:ok, normalize(record)}

        true ->
          {:error, :workflow_write_outcome_unknown}
      end
    end
  end

  def archive(user_id, workflow_id, now) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET archived_at = $now, updated_at = $now
    WHERE user_id = $owner AND archived_at = $empty
    RETURN AFTER;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @table,
             "id" => workflow_id,
             "owner" => user_id,
             "empty" => nil,
             "now" => Surreal.datetime(now)
           }),
         {:ok, record} <- single(results) do
      cond do
        is_nil(record) ->
          {:error, :not_found}

        record["workflow_id"] == workflow_id and record["user_id"] == user_id and
            not is_nil(record["archived_at"]) ->
          {:ok, normalize(record)}

        true ->
          {:error, :workflow_write_outcome_unknown}
      end
    end
  end

  @doc "The full immutable binding for this owner's submission, including legacy records."
  def get_run(user_id, submission_id) do
    statement = "SELECT * FROM ONLY type::record($table, $id);"

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @run_table,
             "id" => run_id(user_id, submission_id)
           }),
         {:ok, record} <- single(results) do
      {:ok, record}
    end
  end

  @doc "Links a run submission to the durable job it created (the same id on every retry)."
  def record_run_job(binding, job_id) do
    statement = """
    UPDATE ONLY type::record($table, $id) SET job_id = $job_id
    WHERE user_id = $owner AND submission_id = $submission AND binding_version = 1
      AND request_sha256 = $digest AND expected_job_id = $job_id
      AND (job_id = $empty OR job_id = $job_id)
    RETURN AFTER;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @run_table,
             "id" => run_id(binding["user_id"], binding["submission_id"]),
             "owner" => binding["user_id"],
             "submission" => binding["submission_id"],
             "digest" => binding["request_sha256"],
             "empty" => nil,
             "job_id" => job_id
           }),
         {:ok, record} when is_map(record) <- single(results),
         true <-
           record["job_id"] == job_id and binding_digest(record) == binding["request_sha256"] and
             record["request_sha256"] == binding["request_sha256"] do
      :ok
    else
      _ -> {:error, :run_outcome_unknown}
    end
  end

  @doc "This owner's runs of one workflow that reached a durable job, newest first."
  def list_runs(user_id, workflow_id, limit) do
    statement = """
    SELECT * FROM workflow_run
    WHERE user_id = $user_id AND workflow_id = $workflow_id AND job_id != $none
    ORDER BY created_at DESC
    LIMIT $limit;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "user_id" => user_id,
             "workflow_id" => workflow_id,
             "none" => nil,
             "limit" => limit
           }),
         {:ok, rows} <- rows(results) do
      {:ok,
       Enum.map(rows || [], fn row ->
         Map.update(row, "created_at", nil, &encode_time/1)
       end)}
    end
  end

  @doc """
  Claim the immutable request and allocate its chat in one transaction.
  A losing concurrent claim rolls its chat back; a lost acknowledgement is
  recovered by reading this same submission rather than allocating another.
  """
  def claim_run(user_id, submission_id, workflow, message, job_id) do
    statement = """
    BEGIN TRANSACTION;
    LET $current = (SELECT * FROM ONLY type::record($workflow_table, $workflow_id));
    IF $current.user_id != $owner OR $current.archived_at != $empty
      OR $current.version != $version OR $current.definition_sha256 != $definition_digest {
      THROW 'workflow snapshot changed';
    };
    CREATE ONLY type::record($table, $id) CONTENT $run;
    CREATE ONLY type::record('chat', $chat_id) CONTENT $chat;
    COMMIT TRANSACTION;
    """

    chat_id = stable_id(["workflow-chat-v1", user_id, submission_id])
    now = Surreal.datetime(DateTime.utc_now() |> DateTime.to_iso8601())

    run = %{
      "binding_version" => 1,
      "user_id" => user_id,
      "submission_id" => submission_id,
      "chat_id" => chat_id,
      "workflow_id" => workflow["workflow_id"],
      "workflow_version" => workflow["version"],
      "definition" => workflow["definition"],
      "definition_sha256" => workflow["definition_sha256"],
      "message" => message,
      "expected_job_id" => job_id,
      "job_id" => nil,
      "created_at" => now
    }

    run = Map.put(run, "request_sha256", binding_digest(run))

    chat = %{
      "chat_id" => chat_id,
      "user_id" => user_id,
      "title" => workflow["name"],
      "title_source" => "manual",
      "pinned" => false,
      "created_at" => now,
      "updated_at" => now,
      "archived_at" => nil
    }

    # Readback is required on success, contention and uncertain transport alike.
    Surreal.query(statement, %{
      "table" => @run_table,
      "id" => run_id(user_id, submission_id),
      "run" => run,
      "chat" => chat,
      "chat_id" => chat_id,
      "workflow_table" => @table,
      "workflow_id" => workflow["workflow_id"],
      "owner" => user_id,
      "empty" => nil,
      "version" => workflow["version"],
      "definition_digest" => workflow["definition_sha256"]
    })

    case get_run(user_id, submission_id) do
      {:ok, binding} when is_map(binding) -> {:ok, binding}
      _ -> {:error, :run_outcome_unknown}
    end
  end

  def binding_digest(binding) do
    :crypto.hash(
      :sha256,
      Jason.encode!([
        "saved-workflow-run.v1",
        binding["user_id"],
        binding["submission_id"],
        binding["workflow_id"],
        binding["workflow_version"],
        binding["definition_sha256"],
        binding["message"],
        binding["chat_id"],
        binding["expected_job_id"]
      ])
    )
    |> Base.encode16(case: :lower)
  end

  # The owner comes from the authenticated session, never the request body.
  defp run_id(user_id, submission_id) do
    stable_id(["workflow-run-v1", user_id, submission_id])
  end

  defp stable_id(parts) do
    :crypto.hash(:sha256, Jason.encode!(parts))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  defp normalize(record) do
    record
    |> Map.delete("id")
    |> Map.update("created_at", nil, &encode_time/1)
    |> Map.update("updated_at", nil, &encode_time/1)
    |> Map.update("archived_at", nil, &encode_time/1)
  end

  defp matches_fields?(record, expected),
    do: is_map(record) and Enum.all?(expected, fn {field, value} -> record[field] === value end)

  defp encode_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_time(value), do: value

  defp single(results) do
    with {:ok, result} <- rows(results) do
      case result do
        nil -> {:ok, nil}
        [] -> {:ok, nil}
        [record] when is_map(record) -> {:ok, record}
        record when is_map(record) -> {:ok, record}
        other -> {:error, {:unexpected_workflow_result, other}}
      end
    end
  end

  defp rows([%{"status" => "OK", "result" => result} | _]), do: {:ok, result}
  defp rows(other), do: {:error, {:unexpected_surreal_response, other}}
end
