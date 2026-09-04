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
  def update(%Job{} = job) do
    SurrealStore.update(job)
  end

  # ------------------------------------------------------------
  # Queue claim
  # ------------------------------------------------------------

  @spec claim_oldest(pos_integer()) ::
          {:ok, Job.t() | nil}
          | {:error, term()}
  def claim_oldest(lease_seconds \\ 300) do
    SurrealStore.claim_oldest(lease_seconds)
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
             completion_status in @completion_statuses and
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
  # Successful completion
  # ------------------------------------------------------------

  defp apply_completion_to_job(
         %Job{status: status} = job,
         status,
         _attrs
       )
       when status in @completion_statuses do
    {:ok, job, :duplicate}
  end

  defp apply_completion_to_job(
         %Job{status: "processing"} = job,
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
      |> Job.put_result(normalize_result(result))
      |> put_metadata(attrs)

    with {:ok, transitioned_job} <-
           Job.transition(
             job,
             "completed"
           ),
         {:ok, stored_job} <-
           update(transitioned_job) do
      {:ok, stored_job, :applied}
    end
  end

  # ------------------------------------------------------------
  # Approval required
  # ------------------------------------------------------------

  defp apply_completion_to_job(
         %Job{status: "processing"} = job,
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
      |> Job.put_result(normalize_result(result))
      |> put_metadata(attrs)

    with {:ok, transitioned_job} <-
           Job.transition(
             job,
             "waiting_approval"
           ),
         {:ok, stored_job} <-
           update(transitioned_job) do
      {:ok, stored_job, :applied}
    end
  end

  # ------------------------------------------------------------
  # Failed completion
  # ------------------------------------------------------------

  defp apply_completion_to_job(
         %Job{status: "processing"} = job,
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
      job
      |> Job.put_error(error)
      |> put_metadata(attrs)

    with {:ok, transitioned_job} <-
           Job.transition(
             job,
             "failed"
           ),
         {:ok, stored_job} <-
           update(transitioned_job) do
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
         %Job{attempts: attempt},
         attempt
       ) do
    :ok
  end

  defp verify_attempt(
         %Job{attempts: current_attempt},
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
      "value" => result
    }
  end
end
