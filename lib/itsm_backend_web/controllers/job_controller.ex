defmodule ItsmBackendWeb.JobController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Jobs.PublicContract
  alias ItsmBackend.RuntimeConfig

  # ------------------------------------------------------------
  # Create durable job
  # ------------------------------------------------------------

  def create(
        conn,
        _params
      ) do
    with {:ok, payload} <-
           PublicContract.validate_create_request(conn.body_params),
         {:ok, job} <-
           Jobs.create(payload),
         {:ok, response} <-
           PublicContract.build_create_response(
             job.id,
             job.status
           ) do
      conn
      |> put_status(:accepted)
      |> json(response)
    else
      {:error,
       {
         :invalid_job_create_request,
         _reason,
         _details
       }} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "invalid_request"
        })

      {:error,
       {
         :invalid_field,
         field
       }} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "invalid_request",
          field: field
        })

      {:error,
       {
         :invalid_job_create_response,
         _reason,
         _details
       } = reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "job_creation_contract_violation",
          reason: inspect(reason)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "job_creation_failed",
          reason: inspect(reason)
        })
    end
  end

  # ------------------------------------------------------------
  # Get durable job
  # ------------------------------------------------------------

  def show(
        conn,
        %{"id" => job_id}
      ) do
    case Jobs.get(job_id) do
      {:ok, job} ->
        json(
          conn,
          job_response(job)
        )

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "job_not_found"
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "job_lookup_failed",
          reason: inspect(reason)
        })
    end
  end

  # ------------------------------------------------------------
  # Approve durable job
  # ------------------------------------------------------------

  def approve(
        conn,
        %{"id" => job_id}
      ) do
    with {:ok, job} <-
           Jobs.get(job_id),
         {:ok, approval_id} <-
           approval_id(job),
         {:ok, approval_result} <-
           execute_approval(approval_id),
         {:ok, completed_job} <-
           complete_approved_job(
             job,
             approval_result
           ) do
      json(
        conn,
        job_response(completed_job)
      )
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "job_not_found"
        })

      {:error,
       {
         :job_not_waiting_approval,
         current_status
       }} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "job_not_waiting_approval",
          status: current_status
        })

      {:error, :approval_id_missing} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "approval_id_missing"
        })

      {:error,
       {
         :approval_service_failed,
         reason
       }} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{
          error: "approval_service_failed",
          reason: inspect(reason)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "job_approval_failed",
          reason: inspect(reason)
        })
    end
  end

  # ------------------------------------------------------------
  # Resolve persisted approval metadata
  # ------------------------------------------------------------

  defp approval_id(%Job{
         status: "waiting_approval",
         proposed_tool: proposed_tool
       })
       when is_map(proposed_tool) do
    value =
      Map.get(
        proposed_tool,
        "approval_id"
      ) ||
        Map.get(
          proposed_tool,
          :approval_id
        )

    case value do
      approval_id
      when is_binary(approval_id) ->
        approval_id =
          String.trim(approval_id)

        if approval_id == "" do
          {:error, :approval_id_missing}
        else
          {:ok, approval_id}
        end

      _ ->
        {:error, :approval_id_missing}
    end
  end

  defp approval_id(%Job{
         status: "waiting_approval"
       }) do
    {:error, :approval_id_missing}
  end

  defp approval_id(%Job{
         status: status
       }) do
    {:error,
     {
       :job_not_waiting_approval,
       status
     }}
  end

  # ------------------------------------------------------------
  # Execute exact approval through AI service
  # ------------------------------------------------------------

  defp execute_approval(approval_id) do
    ai_client =
      RuntimeConfig.ai_client!()

    case ai_client.approve(approval_id) do
      {:ok, result}
      when is_map(result) ->
        {:ok, result}

      {:ok, result} ->
        {:error,
         {
           :approval_service_failed,
           {
             :invalid_approval_result,
             result
           }
         }}

      {:error, reason} ->
        {:error,
         {
           :approval_service_failed,
           reason
         }}
    end
  end

  # ------------------------------------------------------------
  # Persist successful approval
  # ------------------------------------------------------------

  defp complete_approved_job(
         %Job{
           status: "waiting_approval"
         } = job,
         approval_result
       )
       when is_map(approval_result) do
    previous_result =
      case job.result do
        result
        when is_map(result) ->
          result

        _ ->
          %{}
      end

    completed_result =
      previous_result
      |> Map.put(
        "approval_execution",
        approval_result
      )
      |> Map.put(
        "answer",
        "Approved action executed successfully."
      )

    updated_job =
      Job.put_result(
        job,
        completed_result
      )

    with {:ok, transitioned_job} <-
           Job.transition(
             updated_job,
             "completed"
           ),
         {:ok, stored_job} <-
           Jobs.update(transitioned_job) do
      {:ok, stored_job}
    end
  end

  defp complete_approved_job(
         %Job{status: status},
         _approval_result
       ) do
    {:error,
     {
       :job_not_waiting_approval,
       status
     }}
  end

  # ------------------------------------------------------------
  # Public response
  # ------------------------------------------------------------

  defp job_response(job) do
    %{
      job_id: job.id,
      user_id: job.user_id,
      conversation_id: job.conversation_id,
      message: job.message,
      status: job.status,
      attempts: job.attempts,
      created_at: job.created_at,
      claimed_at: job.claimed_at,
      lease_expires_at: job.lease_expires_at,
      completed_at: job.completed_at,
      selected_agent: job.selected_agent,
      proposed_tool: job.proposed_tool,
      result: job.result,
      error: job.error
    }
  end
end
