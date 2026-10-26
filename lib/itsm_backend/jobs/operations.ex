defmodule ItsmBackend.Jobs.Operations do
  @moduledoc "Owner-scoped operational snapshots and immutable, observational inference accounting."
  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.{InferenceMetric, Job, OperationsStore}

  @terminal ~w(completed failed denied outcome_unknown reconciliation_required)

  def record(job_id, params) do
    with true <- InferenceMetric.valid_id?(job_id) || {:error, :invalid_metric},
         {:ok, input} <- InferenceMetric.validate(params),
         {:ok, job} <- Jobs.get(job_id),
         true <- job.attempts == input["attempt"] || {:error, :stale_attempt} do
      OperationsStore.create(job, input)
    end
  end

  def snapshot(owner, limit)
      when is_binary(owner) and owner != "" and is_integer(limit) and limit in 1..100 do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, count_rows} <- OperationsStore.counts(owner),
         {:ok, counts} <- decode_counts(count_rows),
         {:ok, rows} <- OperationsStore.recent(owner, limit),
         {:ok, jobs} <- jobs(rows, owner, now) do
      {:ok,
       %{
         "schema" => "operations-snapshot.v1",
         "observed_at" => DateTime.to_iso8601(now),
         "counts" => counts,
         "jobs" => jobs
       }}
    end
  end

  def snapshot(_owner, _limit), do: {:error, :invalid_limit}

  defp decode_counts(rows) when is_list(rows) do
    initial = Map.new(Job.statuses(), &{&1, 0})

    Enum.reduce_while(rows, {:ok, initial, MapSet.new()}, fn row, {:ok, counts, seen} ->
      status = if is_map(row), do: row["status"]
      count = if is_map(row), do: row["count"]

      if Map.has_key?(counts, status) and is_integer(count) and count >= 0 and
           not MapSet.member?(seen, status),
         do: {:cont, {:ok, Map.put(counts, status, count), MapSet.put(seen, status)}},
         else: {:halt, {:error, :invalid_operations_storage}}
    end)
    |> case do
      {:ok, counts, _seen} -> {:ok, counts}
      error -> error
    end
  end

  defp decode_counts(_rows), do: {:error, :invalid_operations_storage}

  defp jobs(rows, owner, now) when is_list(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, items} ->
      with true <-
             is_map(row) and row["user_id"] == owner and row["status"] in Job.statuses() and
               InferenceMetric.valid_id?(row["job_id"]) and is_integer(row["attempts"]) and
               row["attempts"] >= 0,
           true <- not is_nil(datetime(row["created_at"])),
           {:ok, metrics} when is_list(metrics) <-
             OperationsStore.metrics(owner, row["job_id"], row["attempts"]),
           true <-
             Enum.all?(metrics, &valid_stored_metric?(&1, owner, row["job_id"], row["attempts"])) do
        {:cont, {:ok, [project(row, metrics, now) | items]}}
      else
        _ -> {:halt, {:error, :operations_storage_unavailable}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp jobs(_rows, _owner, _now), do: {:error, :invalid_operations_storage}

  defp valid_stored_metric?(metric, owner, job_id, attempt) do
    is_map(metric) and metric["user_id"] == owner and metric["job_id"] == job_id and
      metric["attempt"] == attempt and
      match?({:ok, _}, InferenceMetric.validate(Map.take(metric, InferenceMetric.fields()))) and
      not is_nil(datetime(metric["recorded_at"]))
  end

  defp project(row, metrics, now) do
    created = datetime(row["created_at"])
    claimed = datetime(row["claimed_at"])
    completed = datetime(row["completed_at"])
    finish = if row["status"] in @terminal, do: completed, else: now

    %{
      "job_id" => row["job_id"],
      "chat_id" => nullable_text(row["conversation_id"]),
      "status" => row["status"],
      "attempt" => row["attempts"],
      "selected_agent" => nullable_text(row["selected_agent"]),
      "created_at" => row["created_at"],
      "claimed_at" => timestamp(claimed),
      "completed_at" => timestamp(completed),
      "queue_wait_ms" => duration(created, claimed),
      "elapsed_ms" => duration(created, finish),
      "metrics_truncated" => length(metrics) > 64,
      "metrics" => metrics |> Enum.take(64) |> Enum.map(&OperationsStore.public/1)
    }
  end

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _offset} -> date
      _ -> nil
    end
  end

  defp datetime(_value), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(_value), do: nil

  defp nullable_text(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp nullable_text(_value), do: nil

  defp duration(%DateTime{} = start, %DateTime{} = finish) do
    value = DateTime.diff(finish, start, :millisecond)
    if value >= 0, do: value, else: nil
  end

  defp duration(_start, _finish), do: nil
end
