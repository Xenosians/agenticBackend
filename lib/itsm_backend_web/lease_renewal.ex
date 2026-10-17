defmodule ItsmBackendWeb.LeaseRenewal do
  @moduledoc """
  One processing-lease renewal contract for both AI transports: the HTTP
  heartbeat (`POST /api/internal/v1/jobs/:id/heartbeat`) and the `renew_lease`
  event on the AI progress socket.

  A renewal is not a completion. It only proves that the exact durable attempt
  is still alive and may keep holding its processing lease.
  """

  alias ItsmBackend.Jobs
  alias ItsmBackend.RuntimeConfig

  @spec renew(String.t(), pos_integer()) ::
          {:ok, map()}
          | {:error, :not_found | :conflict | :internal_server_error, map()}
  def renew(job_id, attempt) do
    lease_seconds = RuntimeConfig.queue_worker!().lease_seconds

    case Jobs.renew_processing_lease(job_id, attempt, lease_seconds) do
      {:ok, job} ->
        {:ok,
         %{
           job_id: job.id,
           attempt: job.attempts,
           status: job.status,
           lease_expires_at: job.lease_expires_at
         }}

      {:error, :not_found} ->
        {:error, :not_found, %{error: "job_not_found"}}

      {:error, {:stale_attempt, current_attempt, received_attempt}} ->
        {:error, :conflict,
         %{
           error: "stale_attempt",
           current_attempt: current_attempt,
           received_attempt: received_attempt
         }}

      {:error, {:job_not_processing, status}} ->
        {:error, :conflict, %{error: "job_not_processing", status: status}}

      {:error, reason} when reason in [:lease_expired, :lease_missing] ->
        {:error, :conflict, %{error: Atom.to_string(reason)}}

      {:error, reason} ->
        {:error, :internal_server_error, %{error: "heartbeat_failed", reason: inspect(reason)}}
    end
  end
end
