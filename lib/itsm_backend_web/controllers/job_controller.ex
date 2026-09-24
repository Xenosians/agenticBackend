defmodule ItsmBackendWeb.JobController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.Auth.Authorization
  alias ItsmBackend.Chats
  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Jobs.PublicContract
  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.AuthRequest

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
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "job_creation_failed", reason: inspect(reason)})
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
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "job_lookup_failed", reason: inspect(reason)})
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
         {:ok, completed_job} <- complete_approved_job(job, approval_result),
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
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "approval_service_failed", reason: inspect(reason)})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "job_approval_failed", reason: inspect(reason)})
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

  defp complete_approved_job(%Job{status: "waiting_approval"} = job, approval_result)
       when is_map(approval_result) do
    previous_result = if is_map(job.result), do: job.result, else: %{}

    completed_result =
      previous_result
      |> Map.put("approval_execution", approval_result)
      |> Map.put("answer", approval_answer(approval_result))

    with {:ok, transitioned} <-
           job |> Job.put_result(completed_result) |> Job.transition("completed"),
         {:ok, stored} <- Jobs.update(transitioned) do
      {:ok, stored}
    end
  end

  defp complete_approved_job(%Job{status: status}, _),
    do: {:error, {:job_not_waiting_approval, status}}

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
