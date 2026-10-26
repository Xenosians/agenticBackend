defmodule ItsmBackend.Jobs.OperationsStore do
  @moduledoc false
  alias ItsmBackend.{Jobs, Surreal}
  alias ItsmBackend.Jobs.InferenceMetric

  @table "job_metric"
  @binding InferenceMetric.fields() ++ ~w(user_id job_id)

  def counts(owner) do
    query("SELECT status, count() AS count FROM job WHERE user_id = $owner GROUP BY status;", %{
      "owner" => owner
    })
  end

  def recent(owner, limit) do
    query(
      """
      SELECT job_id, user_id, conversation_id, status, attempts, created_at, claimed_at,
             completed_at, selected_agent FROM job WHERE user_id = $owner
      ORDER BY created_at DESC LIMIT $limit;
      """,
      %{"owner" => owner, "limit" => limit}
    )
  end

  def metrics(owner, job_id, attempt) do
    query(
      """
      SELECT * FROM job_metric WHERE user_id = $owner AND job_id = $job_id AND attempt = $attempt
      ORDER BY recorded_at ASC LIMIT 65;
      """,
      %{"owner" => owner, "job_id" => job_id, "attempt" => attempt}
    )
  end

  def create(job, input) do
    id =
      :crypto.hash(
        :sha256,
        Jason.encode!(["inference-metric-v1", job.id, job.attempts, input["event_id"]])
      )
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)

    record =
      Map.merge(input, %{
        "job_id" => job.id,
        "user_id" => job.user_id,
        "recorded_at" =>
          DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
      })

    statement = """
    BEGIN TRANSACTION;
    LET $current_job = SELECT * FROM ONLY type::record('job', $job_id);
    IF $current_job = NONE OR $current_job.user_id != $owner OR $current_job.attempts != $attempt {
      THROW 'metric_attempt_mismatch';
    };
    CREATE ONLY type::record($table, $id) CONTENT $metric;
    COMMIT TRANSACTION;
    """

    result =
      Surreal.query(statement, %{
        "job_id" => job.id,
        "owner" => job.user_id,
        "attempt" => job.attempts,
        "table" => @table,
        "id" => id,
        "metric" => Surreal.datetime_fields(record, ~w(recorded_at))
      })

    case result do
      {:ok, _} ->
        confirm(id, record, :created)

      {:error, _} ->
        case Jobs.get(job.id) do
          {:ok, current}
          when current.attempts != job.attempts or current.user_id != job.user_id ->
            {:error, :stale_attempt}

          {:ok, _} ->
            confirm(id, record, :existing)

          {:error, :not_found} ->
            {:error, :not_found}

          _ ->
            {:error, :metric_outcome_unknown}
        end
    end
  end

  def public(record) do
    {:ok, input} = InferenceMetric.validate(Map.take(record, InferenceMetric.fields()))
    Map.put(input, "recorded_at", record["recorded_at"])
  end

  defp confirm(id, expected, disposition) do
    case query("SELECT * FROM ONLY type::record($table, $id);", %{"table" => @table, "id" => id}) do
      {:ok, record} when is_map(record) ->
        confirm_record(record, expected, disposition)

      {:ok, [record]} when is_map(record) ->
        confirm_record(record, expected, disposition)

      _ ->
        {:error, :metric_outcome_unknown}
    end
  end

  defp confirm_record(record, expected, disposition) do
    cond do
      Map.take(record, @binding) != Map.take(expected, @binding) ->
        {:error, :metric_conflict}

      not is_binary(record["recorded_at"]) ->
        {:error, :metric_outcome_unknown}

      not match?({:ok, _, _}, DateTime.from_iso8601(record["recorded_at"])) ->
        {:error, :metric_outcome_unknown}

      true ->
        {:ok, public(record), disposition}
    end
  end

  defp query(statement, params) do
    case Surreal.query(statement, params) do
      {:ok, [%{"status" => "OK", "result" => result}]} -> {:ok, result}
      _ -> {:error, :operations_storage_unavailable}
    end
  end
end
