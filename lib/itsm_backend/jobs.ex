defmodule ItsmBackend.Jobs do
  @moduledoc """
  Public application API for durable AI jobs.
  """

  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Jobs.SurrealStore

  @completion_statuses [
    "completed",
    "failed",
    "waiting_approval"
  ]

  @terminal_statuses [
    "completed",
    "failed"
  ]

  # ------------------------------------------------------------
  # Create
  # ------------------------------------------------------------

  @spec create(map()) ::
          {:ok, Job.t()}
          | {:error, term()}
  def create(attrs)
      when is_map(attrs) do
    with {:ok, job} <-
           Job.new(attrs),
         {:ok, stored_job} <-
           SurrealStore.create(job) do
      {:ok, stored_job}
    end
  end

  # ------------------------------------------------------------
  # Get
  # ------------------------------------------------------------

  @spec get(String.t()) ::
          {:ok, Job.t()}
          | {:error, term()}
  def get(job_id)
      when is_binary(job_id) do
    SurrealStore.get(job_id)
  end

  # ------------------------------------------------------------
  # Update
  # ------------------------------------------------------------

  @spec update(Job.t()) ::
          {:ok, Job.t()}
          | {:error, term()}
  def update(
        %Job{} = job
      ) do
    SurrealStore.update(job)
  end

  # ------------------------------------------------------------
  # Queue claim
  # ------------------------------------------------------------

  @spec claim_oldest(pos_integer()) ::
          {:ok, Job.t() | nil}
          | {:error, term()}
  def claim_oldest(lease_seconds) do
    SurrealStore.claim_oldest(
      lease_seconds
    )
  end

  # ------------------------------------------------------------
  # Processing lease renewal
  #
  # Heartbeats extend only the exact active attempt.
  #
  # SurrealDB performs the authoritative compare-and-set.
  #
  # If a concurrent heartbeat already renewed the same attempt,
  # the follow-up read is treated as idempotent success.
  # ------------------------------------------------------------

  @spec renew_processing_lease(
          String.t(),
          pos_integer(),
          pos_integer()
        ) ::
          {:ok, Job.t()}
          | {:error, term()}
  def renew_processing_lease(
        job_id,
        attempt,
        lease_seconds
      )
      when is_binary(job_id) and
             is_integer(attempt) and
             attempt > 0 and
             is_integer(lease_seconds) and
             lease_seconds > 0 do
    case SurrealStore.renew_processing_lease(
           job_id,
           attempt,
           lease_seconds
         ) do
      {:ok, %Job{} = job} ->
        {:ok, job}

      {:ok, nil} ->
        resolve_failed_lease_renewal(
          job_id,
          attempt
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  def renew_processing_lease(
        job_id,
        attempt,
        lease_seconds
      ) do
    {:error,
     {
       :invalid_lease_renewal,
       job_id,
       attempt,
       lease_seconds
     }}
  end

  defp resolve_failed_lease_renewal(
         job_id,
         incoming_attempt
       ) do
    case get(job_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}

      {:ok,
       %Job{
         attempts: current_attempt
       }}
      when current_attempt !=
             incoming_attempt ->
        {:error,
         {
           :stale_attempt,
           current_attempt,
           incoming_attempt
         }}

      {:ok,
       %Job{
         status: status
       }}
      when status !=
             "processing" ->
        {:error,
         {
           :job_not_processing,
           status
         }}

      {:ok,
       %Job{
         lease_expires_at: nil
       }} ->
        {:error, :lease_missing}

      {:ok,
       %Job{
         lease_expires_at:
           %DateTime{} = lease_expires_at
       } = job} ->
        now =
          DateTime.utc_now()

        if DateTime.compare(
             lease_expires_at,
             now
           ) in [:lt, :eq] do
          {:error, :lease_expired}
        else
          # A concurrent heartbeat may already have renewed
          # this exact attempt after our conditional UPDATE
          # observed no row. Treat the currently healthy lease
          # as idempotent success.
          {:ok, job}
        end
    end
  end

  # ------------------------------------------------------------
  # Expired processing discovery
  # ------------------------------------------------------------

  @spec find_oldest_expired_processing(
          DateTime.t()
        ) ::
          {:ok, Job.t() | nil}
          | {:error, term()}
  def find_oldest_expired_processing(
        now \\ DateTime.utc_now()
      ) do
    SurrealStore.find_oldest_expired_processing(
      now
    )
  end

  # ------------------------------------------------------------
  # Fail-closed lease recovery
  # ------------------------------------------------------------

  @spec fail_processing_if_current(
          Job.t(),
          String.t()
        ) ::
          {:ok, Job.t() | nil}
          | {:error, term()}
  def fail_processing_if_current(
        %Job{} = job,
        error
      )
      when is_binary(error) do
    SurrealStore.fail_processing_if_current(
      job,
      error
    )
  end

  # ------------------------------------------------------------
  # AI completion callback
  # Handshake #2
  # ------------------------------------------------------------

  @spec apply_completion(
          String.t(),
          pos_integer(),
          String.t(),
          map()
        ) ::
          {:ok, Job.t(), :applied | :duplicate}
          | {:error, term()}
  def apply_completion(
        job_id,
        attempt,
        completion_status,
        attrs
      )
      when is_binary(job_id) and
             is_integer(attempt) and
             attempt > 0 and
             completion_status in
               @completion_statuses and
             is_map(attrs) do
    with {:ok, job} <-
           get(job_id),
         :ok <-
           verify_attempt(
             job,
             attempt
           ) do
      apply_completion_to_job(
        job,
        completion_status,
        attrs
      )
    end
  end

  def apply_completion(
        _job_id,
        _attempt,
        status,
        _attrs
      ) do
    {:error,
     {
       :invalid_completion_status,
       status
     }}
  end

  # ------------------------------------------------------------
  # Exact duplicate completion
  # ------------------------------------------------------------

  defp apply_completion_to_job(
         %Job{
           status: status
         } = job,
         status,
         _attrs
       )
       when status in
              @completion_statuses do
    {:ok, job, :duplicate}
  end

  # ------------------------------------------------------------
  # Terminal state wins
  # ------------------------------------------------------------

  defp apply_completion_to_job(
         %Job{
           status: status
         } = job,
         _completion_status,
         _attrs
       )
       when status in
              @terminal_statuses do
    {:ok, job, :duplicate}
  end

  # ------------------------------------------------------------
  # Successful completion
  # ------------------------------------------------------------

  defp apply_completion_to_job(
         %Job{
           status: "processing"
         } = job,
         "completed",
         attrs
       ) do
    result =
      Map.get(
        attrs,
        "result",
        %{}
      )

    job =
      job
      |> Job.put_result(
        normalize_result(
          result
        )
      )
      |> put_metadata(
        attrs
      )

    with {:ok, transitioned_job} <-
           Job.transition(
             job,
             "completed"
           ),
         {:ok, stored_job} <-
           update(
             transitioned_job
           ) do
      {:ok, stored_job, :applied}
    end
  end

  # ------------------------------------------------------------
  # Approval required
  # ------------------------------------------------------------

  defp apply_completion_to_job(
         %Job{
           status: "processing"
         } = job,
         "waiting_approval",
         attrs
       ) do
    result =
      Map.get(
        attrs,
        "result",
        %{}
      )

    job =
      job
      |> Job.put_result(
        normalize_result(
          result
        )
      )
      |> put_metadata(
        attrs
      )

    with {:ok, transitioned_job} <-
           Job.transition(
             job,
             "waiting_approval"
           ),
         {:ok, stored_job} <-
           update(
             transitioned_job
           ) do
      {:ok, stored_job, :applied}
    end
  end

  # ------------------------------------------------------------
  # Failed completion
  # ------------------------------------------------------------

  defp apply_completion_to_job(
         %Job{
           status: "processing"
         } = job,
         "failed",
         attrs
       ) do
    error =
      Map.get(
        attrs,
        "error",
        "AI job failed"
      )

    job =
      Job.put_error(
        job,
        error
      )

    job =
      put_metadata(
        job,
        attrs
      )

    with {:ok, transitioned_job} <-
           Job.transition(
             job,
             "failed"
           ),
         {:ok, stored_job} <-
           update(
             transitioned_job
           ) do
      {:ok, stored_job, :applied}
    end
  end

  # ------------------------------------------------------------
  # Invalid state
  # ------------------------------------------------------------

  defp apply_completion_to_job(
         %Job{} = job,
         completion_status,
         _attrs
       ) do
    {:error,
     {
       :invalid_completion_state,
       job.status,
       completion_status
     }}
  end

  # ------------------------------------------------------------
  # Attempt protection
  # ------------------------------------------------------------

  defp verify_attempt(
         %Job{
           attempts: attempt
         },
         attempt
       ) do
    :ok
  end

  defp verify_attempt(
         %Job{
           attempts: current_attempt
         },
         incoming_attempt
       ) do
    {:error,
     {
       :stale_attempt,
       current_attempt,
       incoming_attempt
     }}
  end

  # ------------------------------------------------------------
  # AI metadata
  # ------------------------------------------------------------

  defp put_metadata(
         %Job{} = job,
         attrs
       ) do
    Job.put_ai_metadata(
      job,
      selected_agent:
        Map.get(
          attrs,
          "selected_agent"
        ),
      proposed_tool:
        Map.get(
          attrs,
          "proposed_tool"
        )
    )
  end

  # ------------------------------------------------------------
  # Result normalization
  # ------------------------------------------------------------

  defp normalize_result(result)
       when is_map(result) do
    result
  end

  defp normalize_result(result) do
    %{
      "value" =>
        result
    }
  end
end
