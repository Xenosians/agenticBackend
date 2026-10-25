defmodule ItsmBackend.JobQueueTestSupport do
  @moduledoc false

  import ExUnit.Assertions, only: [flunk: 1]

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job

  @doc """
  Fails closed every processing row whose lease has already expired.

  Tests share one database, and a QueueWorker recovers the oldest expired
  processing row before it dispatches anything. A row another test left
  behind would therefore take a worker test's tick. Only already-expired
  rows change, through the production compare-and-set recovery.
  """
  def drain_expired_processing!(reason) when is_binary(reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Jobs.find_oldest_expired_processing(now) do
      {:ok, nil} ->
        :ok

      {:ok, %Job{} = expired} ->
        case Jobs.fail_processing_if_current(expired, reason) do
          {:ok, _result} -> drain_expired_processing!(reason)
          {:error, error} -> flunk("failed to clean expired processing row: #{inspect(error)}")
        end

      {:error, error} ->
        flunk("failed to discover expired processing rows: #{inspect(error)}")
    end
  end
end
