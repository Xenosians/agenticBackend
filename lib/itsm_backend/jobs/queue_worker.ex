defmodule ItsmBackend.Jobs.QueueWorker do
  @moduledoc """
  OTP worker responsible for dispatching durable pending jobs
  to the Python AI service.

  Phoenix/SurrealDB remain the durable owner of job state.

  The worker:

  1. Checks AI readiness.
  2. Atomically claims the oldest pending job.
  3. Sends the job to FastAPI.
  4. Expects a 202 Accepted acknowledgement.
  5. Keeps at most one locally tracked in-flight job.

  Completion handling is performed by the second handshake,
  which will be added separately.
  """

  use GenServer

  require Logger

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job

  # ------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(
      __MODULE__,
      opts,
      name: __MODULE__
    )
  end

  # ------------------------------------------------------------
  # GenServer lifecycle
  # ------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      poll_interval_ms:
        Keyword.get(
          opts,
          :poll_interval_ms,
          1_000
        ),
      lease_seconds:
        Keyword.get(
          opts,
          :lease_seconds,
          300
        ),
      inflight_job_id: nil
    }

    send(
      self(),
      :tick
    )

    {:ok, state}
  end

  # ------------------------------------------------------------
  # Poll loop
  # ------------------------------------------------------------

  @impl true
  def handle_info(
        :tick,
        state
      ) do
    next_state =
      case state.inflight_job_id do
        nil ->
          maybe_dispatch(state)

        job_id ->
          check_inflight(
            job_id,
            state
          )
      end

    schedule_tick(next_state.poll_interval_ms)

    {:noreply, next_state}
  end

  # ------------------------------------------------------------
  # Dispatch
  # ------------------------------------------------------------

  defp maybe_dispatch(state) do
    ai_client =
      Application.fetch_env!(
        :itsm_backend,
        :ai_client
      )

    case ai_client.ready() do
      {:ok, _body} ->
        claim_and_dispatch(
          ai_client,
          state
        )

      {:error, reason} ->
        Logger.debug(
          "AI service not ready: " <>
            inspect(reason)
        )

        state
    end
  end

  defp claim_and_dispatch(
         ai_client,
         state
       ) do
    case Jobs.claim_oldest(state.lease_seconds) do
      {:ok, nil} ->
        state

      {:ok, %Job{} = job} ->
        dispatch_job(
          ai_client,
          job,
          state
        )

      {:error, reason} ->
        Logger.error(
          "Failed to claim pending job: " <>
            inspect(reason)
        )

        state
    end
  end

  defp dispatch_job(
         ai_client,
         %Job{} = job,
         state
       ) do
    Logger.info(
      "Dispatching AI job " <>
        "job_id=#{job.id}"
    )

    case ai_client.execute_job(
           job.id,
           job.user_id,
           job.message
         ) do
      {:ok, ack} ->
        Logger.info(
          "AI job accepted " <>
            "job_id=#{job.id} " <>
            "ack=#{inspect(ack)}"
        )

        %{
          state
          | inflight_job_id: job.id
        }

      {:error,
       {
         :ai_service_error,
         status,
         reason
       }}
      when status in 400..499 ->
        Logger.warning(
          "AI rejected job " <>
            "job_id=#{job.id} " <>
            "status=#{status} " <>
            "reason=#{inspect(reason)}"
        )

        safely_requeue(job)

        state

      {:error, reason} ->
        # Important:
        #
        # A network failure can be ambiguous.
        # Python may have accepted the job even if Phoenix
        # did not receive the ACK.
        #
        # Do NOT immediately requeue here because that could
        # execute externally-visible operations twice.
        #
        # Leave the job processing until its lease expires.
        Logger.error(
          "Ambiguous AI dispatch failure " <>
            "job_id=#{job.id} " <>
            "reason=#{inspect(reason)}"
        )

        %{
          state
          | inflight_job_id: job.id
        }
    end
  end

  # ------------------------------------------------------------
  # In-flight tracking
  # ------------------------------------------------------------

  defp check_inflight(
         job_id,
         state
       ) do
    case Jobs.get(job_id) do
      {:ok,
       %Job{
         status: "processing"
       } = job} ->
        if lease_expired?(job) do
          Logger.warning(
            "AI job lease expired " <>
              "job_id=#{job.id}"
          )

          %{
            state
            | inflight_job_id: nil
          }
        else
          state
        end

      {:ok, %Job{} = job} ->
        Logger.info(
          "AI job left processing state " <>
            "job_id=#{job.id} " <>
            "status=#{job.status}"
        )

        %{
          state
          | inflight_job_id: nil
        }

      {:error, :not_found} ->
        Logger.warning(
          "In-flight job disappeared " <>
            "job_id=#{job_id}"
        )

        %{
          state
          | inflight_job_id: nil
        }

      {:error, reason} ->
        Logger.error(
          "Failed to read in-flight job " <>
            "job_id=#{job_id} " <>
            "reason=#{inspect(reason)}"
        )

        state
    end
  end

  # ------------------------------------------------------------
  # Safe requeue
  # ------------------------------------------------------------

  defp safely_requeue(%Job{} = job) do
    with {:ok, pending_job} <-
           Job.transition(
             job,
             "pending"
           ),
         {:ok, _stored_job} <-
           Jobs.update(pending_job) do
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "Failed to requeue rejected job " <>
            "job_id=#{job.id} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # ------------------------------------------------------------
  # Lease helpers
  # ------------------------------------------------------------

  defp lease_expired?(%Job{
         lease_expires_at: nil
       }) do
    false
  end

  defp lease_expired?(%Job{
         lease_expires_at: %DateTime{} = expires_at
       }) do
    now =
      DateTime.utc_now()

    DateTime.compare(
      expires_at,
      now
    ) in [:lt, :eq]
  end

  # ------------------------------------------------------------
  # Scheduling
  # ------------------------------------------------------------

  defp schedule_tick(poll_interval_ms) do
    Process.send_after(
      self(),
      :tick,
      poll_interval_ms
    )
  end
end
