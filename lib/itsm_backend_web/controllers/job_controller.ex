defmodule ItsmBackendWeb.JobController do
  use ItsmBackendWeb, :controller

  use ItsmBackendWeb.RequestContract

  # SRS18_REQUEST_CONTRACT_V1
  request_contract(:create,
    required_body: ["chat_id", "message"]
  )

  request_contract(:show, [])
  request_contract(:approve, [])

  require Logger

  alias ItsmBackend.Auth.Authorization
  alias ItsmBackend.Chats
  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.ApprovalOutcome
  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Jobs.PublicContract
  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.AuthRequest
  alias ItsmBackendWeb.PublicError

  def create(conn, _params) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} -> create_authenticated(conn, ctx.user)
      {:error, conn} -> conn
    end
  end

  defp create_authenticated(conn, user) do
    with {:ok, payload} <- PublicContract.validate_create_request(conn.body_params),
         {:ok, _chat} <- Chats.get_authorized(user, payload["chat_id"]),
         {:ok, _chat} <- Chats.touch(payload["chat_id"]),
         {:ok, job} <-
           Jobs.create(%{
             "user_id" => user["user_id"],
             "conversation_id" => payload["chat_id"],
             "message" => payload["message"]
           }),
         {:ok, response} <- PublicContract.build_create_response(job.id, job.status) do
      conn
      |> put_status(:accepted)
      |> json(response)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "chat_not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, {:invalid_job_create_request, _, _}} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_request"})

      {:error, reason} ->
        Logger.error("job creation failed: #{inspect(reason)}")

        PublicError.render(
          conn,
          :internal_server_error,
          "job_creation_failed",
          "The job could not be created."
        )
    end
  end

  def show(conn, %{"id" => job_id}) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} -> show_authenticated(conn, ctx.user, job_id)
      {:error, conn} -> conn
    end
  end

  defp show_authenticated(conn, user, job_id) do
    with {:ok, job} <- Jobs.get(job_id),
         true <- Authorization.owns_resource?(user, job.user_id) || {:error, :forbidden},
         {:ok, response} <- PublicContract.build_job_response(job) do
      json(conn, response)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "job_not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, reason} ->
        Logger.error("job lookup failed: #{inspect(reason)}")

        PublicError.render(
          conn,
          :internal_server_error,
          "job_lookup_failed",
          "The job could not be loaded.",
          retryable: true
        )
    end
  end

  def approve(conn, %{"id" => job_id}) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} -> approve_authenticated(conn, ctx.user, job_id)
      {:error, conn} -> conn
    end
  end

  defp approve_authenticated(conn, user, job_id) do
    with {:ok, job} <- Jobs.get(job_id),
         true <- Authorization.owns_resource?(user, job.user_id) || {:error, :forbidden},
         {:ok, approval_id} <- approval_id(job),
         {:ok, approval_result} <- execute_approval(approval_id),
         {:ok, approval_outcome} <- ApprovalOutcome.normalize(approval_result),
         {:ok, completed_job} <- complete_approved_job(job, approval_outcome),
         {:ok, response} <- PublicContract.build_job_response(completed_job) do
      json(conn, response)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "job_not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, {:job_not_waiting_approval, status}} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "job_not_waiting_approval", status: status})

      {:error, :approval_id_missing} ->
        conn |> put_status(:conflict) |> json(%{error: "approval_id_missing"})

      {:error, {:approval_service_failed, reason}} ->
        Logger.error("approval service failed: #{inspect(reason)}")

        PublicError.render(
          conn,
          :bad_gateway,
          "approval_service_failed",
          "The approval request could not be delivered to the AI service.",
          retryable: true
        )

      {:error, {:invalid_approval_outcome, reason}} ->
        Logger.error("invalid approval outcome: #{inspect(reason)}")

        PublicError.render(
          conn,
          :bad_gateway,
          "approval_contract_invalid",
          "The AI service returned an invalid approval outcome.",
          retryable: true
        )

      {:error, reason} ->
        Logger.error("job approval failed: #{inspect(reason)}")

        PublicError.render(
          conn,
          :internal_server_error,
          "job_approval_failed",
          "The approval could not be completed."
        )
    end
  end

  defp approval_id(%Job{status: "waiting_approval", proposed_tool: proposed_tool})
       when is_map(proposed_tool) do
    value = Map.get(proposed_tool, "approval_id") || Map.get(proposed_tool, :approval_id)

    if is_binary(value) and String.trim(value) != "",
      do: {:ok, String.trim(value)},
      else: {:error, :approval_id_missing}
  end

  defp approval_id(%Job{status: "waiting_approval"}), do: {:error, :approval_id_missing}
  defp approval_id(%Job{status: status}), do: {:error, {:job_not_waiting_approval, status}}

  defp execute_approval(approval_id) do
    case RuntimeConfig.ai_client!().approve(approval_id) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:ok, result} -> {:error, {:approval_service_failed, {:invalid_approval_result, result}}}
      {:error, reason} -> {:error, {:approval_service_failed, reason}}
    end
  end

  defp complete_approved_job(
         %Job{status: "waiting_approval"} = job,
         approval_outcome
       )
       when is_map(approval_outcome) do
    previous_result =
      if is_map(job.result), do: job.result, else: %{}

    target_status =
      ApprovalOutcome.target_job_status(approval_outcome)

    message =
      ApprovalOutcome.message(approval_outcome)

    stored_result =
      previous_result
      |> Map.put("approval_execution", approval_outcome)
      |> put_approval_answer(target_status, approval_outcome, message)

    job = Job.put_result(job, stored_result)

    job =
      if target_status in ["failed", "reconciliation_required"] do
        Job.put_error(
          job,
          message || "Approved action did not complete successfully."
        )
      else
        job
      end

    with {:ok, transitioned} <- Job.transition(job, target_status),
         {:ok, stored} <- Jobs.update(transitioned) do
      {:ok, stored}
    end
  end

  defp complete_approved_job(%Job{status: status}, _),
    do: {:error, {:job_not_waiting_approval, status}}

  defp put_approval_answer(result, "completed", approval_outcome, _message) do
    Map.put(
      result,
      "answer",
      approval_answer(approval_outcome)
    )
  end

  defp put_approval_answer(result, _status, _approval_outcome, message) do
    Map.put(
      result,
      "answer",
      message || "Approved action requires operator attention."
    )
  end

  defp approval_answer(result) do
    Map.get(result, "answer") ||
      Map.get(result, :answer) ||
      nested_approval_answer(Map.get(result, "result") || Map.get(result, :result)) ||
      "Approved action executed successfully."
  end

  defp nested_approval_answer(value) when is_map(value) do
    Map.get(value, "answer") ||
      Map.get(value, :answer) ||
      Map.get(value, "message") ||
      Map.get(value, :message)
  end

  defp nested_approval_answer(_), do: nil
end
