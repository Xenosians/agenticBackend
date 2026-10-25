defmodule ItsmBackend.Jobs.QueueWorker do
  @moduledoc """
  OTP worker responsible for dispatching durable pending jobs
  to the Python AI service and reconciling expired processing
  attempts.

  Phoenix/SurrealDB remain the durable owner of job state.

  The worker:

  1. Reconciles one expired durable processing attempt when idle.
  2. Checks AI readiness when no recovery work is pending.
  3. Atomically claims the oldest pending job.
  4. Sends the job to FastAPI.
  5. Expects a 202 Accepted acknowledgement.
  6. Keeps at most one locally tracked in-flight job.
  7. Observes durable completion state.
  8. Fails expired processing attempts closed without automatic
     redispatch.

  Completion handling itself is performed through the durable
  AI completion callback.
  """

  use GenServer

  require Logger

  alias ItsmBackend.Chats
  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.RuntimeConfig

  @lease_expired_error "Processing lease expired before durable AI completion. " <>
                         "Execution outcome is ambiguous, so automatic retry " <>
                         "was suppressed."

  @workflow_client_error "workflow_client_unsupported: The configured AI client does not support " <>
                           "reviewed workflows. No AI execution was dispatched."

  # Request validation, internal authentication and endpoint negotiation reject
  # the request before the AI endpoint schedules work. Retrying the unchanged
  # durable request cannot repair these failures. A timeout/conflict response is
  # not proof that work was rejected and must retain the ambiguous-outcome path.
  @permanent_rejection_statuses [400, 401, 403, 404, 405, 413, 415, 422]

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
        Keyword.fetch!(
          opts,
          :poll_interval_ms
        ),
      lease_seconds:
        Keyword.fetch!(
          opts,
          :lease_seconds
        ),
      inflight_job_id: nil,
      undispatched_failure: nil
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
      case state.undispatched_failure do
        %Job{} = job ->
          persist_undispatched_failure(job, state)

        nil ->
          case state.inflight_job_id do
            nil -> reconcile_or_dispatch(state)
            job_id -> check_inflight(job_id, state)
          end
      end

    schedule_tick(next_state.poll_interval_ms)

    {:noreply, next_state}
  end

  # ------------------------------------------------------------
  # Idle reconciliation
  # ------------------------------------------------------------

  defp reconcile_or_dispatch(state) do
    recovery_time =
      DateTime.utc_now()
      |> DateTime.truncate(:microsecond)

    case Jobs.find_oldest_expired_processing(recovery_time) do
      {:ok, nil} ->
        maybe_dispatch(state)

      {:ok, %Job{} = job} ->
        Logger.warning(
          "Discovered expired durable AI job " <>
            "job_id=#{job.id} " <>
            "attempt=#{job.attempts}"
        )

        recover_expired_processing(
          job,
          state
        )

      {:error, reason} ->
        Logger.error(
          "Failed to discover expired processing jobs: " <>
            inspect(reason)
        )

        state
    end
  end

  # ------------------------------------------------------------
  # Dispatch
  # ------------------------------------------------------------

  defp maybe_dispatch(state) do
    case Jobs.pending?() do
      {:ok, false} ->
        state

      {:ok, true} ->
        maybe_dispatch_pending(state)

      {:error, reason} ->
        Logger.error(
          "Failed to inspect pending AI jobs: " <>
            inspect(reason)
        )

        state
    end
  end

  defp maybe_dispatch_pending(state) do
    ai_client =
      RuntimeConfig.ai_client!()

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

    case dispatch_to_ai(ai_client, job) do
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

      {:error, {:context_projection_failed, reason}} ->
        Logger.error(
          "Failed to project bounded chat context " <>
            "job_id=#{job.id} " <>
            "reason=#{inspect(reason)}"
        )

        # No AI dispatch occurred, so this pre-dispatch failure is safe
        # to requeue.
        safely_requeue(job)
        state

      {:error, {:ai_client_missing_workflow_callback, ^ai_client}} ->
        # The compatibility boundary verified that no workflow callback exists;
        # no model request or tool operation was invoked. Persist a known failure
        # rather than waiting for an execution lease and inventing uncertainty.
        persist_undispatched_failure(Job.put_error(job, @workflow_client_error), state)

      {:error, {:ai_service_error, status, _body}}
      when status in @permanent_rejection_statuses ->
        Logger.warning("AI rejected durable request job_id=#{job.id} status=#{status}")

        # Neither persist nor log the service body: validation/auth responses
        # can contain submitted context or infrastructure details.
        error =
          "ai_request_rejected: AI refused this request before execution (HTTP #{status}). " <>
            "Correct the request or service configuration before submitting new work."

        persist_undispatched_failure(Job.put_error(job, error), state)

      {:error,
       {
         :ai_service_error,
         status,
         _reason
       }}
      when status == 429 ->
        Logger.warning(
          "AI rejected job " <>
            "job_id=#{job.id} " <>
            "status=#{status}"
        )

        safely_requeue(job)

        state

      {:error, reason} ->
        Logger.error(
          "Ambiguous AI dispatch failure " <>
            "job_id=#{job.id} " <>
            "reason=#{inspect(dispatch_error_summary(reason))}"
        )

        %{
          state
          | inflight_job_id: job.id
        }
    end
  end

  defp dispatch_error_summary({:ai_service_error, status, _body}),
    do: {:ai_service_error, status}

  defp dispatch_error_summary(reason), do: reason

  defp persist_undispatched_failure(%Job{} = job, state) do
    case Jobs.fail_processing_if_current(job, job.error, "failed") do
      {:ok, %Job{status: "failed"}} ->
        %{state | inflight_job_id: nil, undispatched_failure: nil}

      {:ok, nil} ->
        # A concurrent state, attempt or lease change invalidated this exact
        # disposition. Never overwrite it or dispatch the request again.
        %{state | inflight_job_id: nil, undispatched_failure: nil}

      {:error, reason} ->
        Logger.error(
          "Failed to persist rejected AI job job_id=#{job.id} reason=#{inspect(reason)}"
        )

        # Retain only the exact failed claim. A later tick retries persistence,
        # never AI dispatch. After a process crash the usual durable recovery is
        # conservative because this local proof is no longer available.
        %{state | inflight_job_id: nil, undispatched_failure: job}
    end
  end

  # ------------------------------------------------------------
  # Bounded chat context projection
  # ------------------------------------------------------------

  defp dispatch_to_ai(ai_client, %Job{} = job) do
    with {:ok, context} <- bounded_context(job) do
      ItsmBackend.AIClient.dispatch_job(
        ai_client,
        job.id,
        job.attempts,
        job.user_id,
        job.message,
        context,
        workflow_binding(job)
      )
    end
  end

  defp workflow_binding(%Job{workflow_contract: nil, workflow_contract_hash: nil}), do: nil

  defp workflow_binding(%Job{} = job) do
    %{
      "workflow_contract" => job.workflow_contract,
      "workflow_contract_hash" => job.workflow_contract_hash
    }
  end

  defp bounded_context(%Job{} = job) do
    auth = RuntimeConfig.auth!()

    if auth.ai_context_enabled and
         is_binary(job.conversation_id) do
      case Chats.ai_context(
             job.user_id,
             job.conversation_id,
             job.id,
             auth.ai_context_max_turns
           ) do
        {:ok, context} when is_list(context) ->
          {:ok, context}

        {:ok, context} ->
          {:error,
           {
             :context_projection_failed,
             {:invalid_context, context}
           }}

        {:error, reason} ->
          {:error,
           {
             :context_projection_failed,
             reason
           }}
      end
    else
      {:ok, []}
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
          recover_expired_processing(
            job,
            state
          )
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
  # Expired processing recovery
  # ------------------------------------------------------------

  defp recover_expired_processing(
         %Job{} = job,
         state
       ) do
    Logger.warning(
      "AI job lease expired " <>
        "job_id=#{job.id} " <>
        "attempt=#{job.attempts}"
    )

    case Jobs.fail_processing_if_current(
           job,
           @lease_expired_error
         ) do
      {:ok,
       %Job{
         status: "outcome_unknown"
       } = failed_job} ->
        Logger.warning(
          "Expired AI job failed closed " <>
            "job_id=#{failed_job.id} " <>
            "attempt=#{failed_job.attempts}"
        )

        %{
          state
          | inflight_job_id: nil
        }

      {:ok, nil} ->
        Logger.info(
          "Lease recovery skipped because durable job " <>
            "state changed concurrently " <>
            "job_id=#{job.id} " <>
            "attempt=#{job.attempts}"
        )

        %{
          state
          | inflight_job_id: nil
        }

      {:error, reason} ->
        Logger.error(
          "Failed to persist lease-expiry recovery " <>
            "job_id=#{job.id} " <>
            "attempt=#{job.attempts} " <>
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
