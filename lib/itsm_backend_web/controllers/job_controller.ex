defmodule ItsmBackendWeb.JobController do
  use ItsmBackendWeb, :controller

  use ItsmBackendWeb.RequestContract

  # SRS18_REQUEST_CONTRACT_V1
  request_contract(:create,
    required_body: ["chat_id", "message"]
  )

  request_contract(:show, [])
  request_contract(:approve, [])
  request_contract(:reject, [])

  require Logger

  alias ItsmBackend.Auth.Authorization
  alias ItsmBackend.Chats
  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.ApprovalOutcome
  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Jobs.JobNotifications
  alias ItsmBackend.Jobs.PublicContract
  alias ItsmBackend.Jobs.WorkflowContinuation
  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.AuthRequest
  alias ItsmBackendWeb.PublicError

  defp wire_version(%{path_info: ["api", "v2" | _]}), do: 2
  defp wire_version(_conn), do: 1

  def create(conn, _params) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} -> create_authenticated(conn, ctx.user)
      {:error, conn} -> conn
    end
  end

  defp create_authenticated(conn, user) do
    with {:ok, payload} <- PublicContract.validate_create_request(conn.body_params),
         {:ok, chat} <- Chats.get_authorized(user, payload["chat_id"]),
         {:ok, _chat} <- Chats.touch(chat["chat_id"]),
         {:ok, job} <-
           Jobs.create(%{
             "user_id" => user["user_id"],
             "conversation_id" => chat["chat_id"],
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
         {:ok, response} <- PublicContract.build_job_response(job, wire_version(conn)) do
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
    decide_approval(conn, job_id, :approve)
  end

  def reject(conn, %{"id" => job_id}) do
    decide_approval(conn, job_id, :reject)
  end

  defp decide_approval(conn, job_id, decision) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} -> decide_approval_authenticated(conn, ctx.user, job_id, decision)
      {:error, conn} -> conn
    end
  end

  defp decide_approval_authenticated(conn, user, job_id, decision) do
    with {:ok, job} <- Jobs.get(job_id),
         true <-
           Authorization.owns_resource?(
             user,
             job.user_id
           ) ||
             {:error, :forbidden},
         {:ok, approval_id} <-
           approval_id(job),
         :ok <- validate_decision_binding(conn.body_params, job, approval_id),
         {:ok, resolved_job} <-
           resolve_approval(
             job,
             approval_id,
             decision
           ),
         {:ok, response} <-
           PublicContract.build_job_response(resolved_job, wire_version(conn)) do
      JobNotifications.enqueue_best_effort(resolved_job)

      json(
        conn,
        response
      )
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "job_not_found"
        })

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "forbidden"
        })

      {:error,
       {
         :job_not_waiting_approval,
         status
       }} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "job_not_waiting_approval",
          status: status
        })

      {:error, :approval_id_missing} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "approval_id_missing"
        })

      {:error, :approval_binding_changed} ->
        conn |> put_status(:conflict) |> json(%{error: "approval_binding_changed"})

      {:error, reason} ->
        Logger.error(
          "job approval failed: " <>
            inspect(reason)
        )

        PublicError.render(
          conn,
          :internal_server_error,
          "job_approval_failed",
          "The approval could not be completed."
        )
    end
  end

  defp validate_decision_binding(body, job, approval_id) do
    submitted = Map.get(body, "approval_id")
    workflow? = get_in(job.result || %{}, ["workflow", "kind"]) == "account_ticket"

    if submitted == approval_id or (submitted == nil and not workflow?),
      do: :ok,
      else: {:error, :approval_binding_changed}
  end

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

    if is_binary(value) and
         String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      {:error, :approval_id_missing}
    end
  end

  defp approval_id(%Job{
         status: "waiting_approval"
       }),
       do: {:error, :approval_id_missing}

  defp approval_id(%Job{
         status: status
       }),
       do:
         {:error,
          {
            :job_not_waiting_approval,
            status
          }}

  defp resolve_approval(
         %Job{
           status: "waiting_approval"
         } = job,
         approval_id,
         decision
       ) do
    case execute_approval_decision(approval_id, decision) do
      {:ok, approval_result} ->
        resolve_authoritative_approval(
          job,
          approval_id,
          approval_result
        )

      {:error,
       {
         :approval_service_failed,
         reason
       }} ->
        reconcile_approval(
          job,
          approval_id,
          {
            :approval_service_failed,
            reason
          }
        )
    end
  end

  defp resolve_approval(
         %Job{
           status: status
         },
         _approval_id,
         _decision
       ) do
    {:error,
     {
       :job_not_waiting_approval,
       status
     }}
  end

  defp resolve_authoritative_approval(
         job,
         approval_id,
         approval_result
       ) do
    with {:ok, approval_outcome} <-
           ApprovalOutcome.normalize(approval_result),
         :ok <-
           ApprovalOutcome.validate_identity(
             approval_outcome,
             approval_id
           ) do
      case WorkflowContinuation.resolve(job, approval_outcome, approval_result["continuation"]) do
        :none -> complete_approved_job(job, approval_outcome)
        {:ok, continued} -> Jobs.continue_approval(job, continued)
        {:error, reason} -> reconcile_approval(job, approval_id, reason)
      end
    else
      {:error, reason} ->
        reconcile_approval(
          job,
          approval_id,
          reason
        )
    end
  end

  defp execute_approval_decision(approval_id, decision) when decision in [:approve, :reject] do
    case apply(RuntimeConfig.ai_client!(), decision, [approval_id]) do
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

  defp reconcile_approval(
         %Job{
           status: "waiting_approval"
         } = job,
         approval_id,
         reason
       ) do
    Logger.warning(
      "approval outcome requires reconciliation " <>
        "job_id=#{job.id} " <>
        "approval_id=#{approval_id} " <>
        "reason=#{inspect(reason)}"
    )

    message =
      "The approval decision has an unresolved outcome. " <>
        "Automatic retry is disabled; trusted reconciliation is required."

    previous_result =
      if is_map(job.result) do
        job.result
      else
        %{}
      end

    reconciliation = %{
      "approval_id" => approval_id,
      "status" => "outcome_unknown",
      "reason_code" => approval_reconciliation_code(reason),
      "automatic_retry" => false
    }

    stored_result =
      previous_result
      |> Map.put(
        "approval_reconciliation",
        reconciliation
      )
      |> Map.put(
        "answer",
        message
      )

    job =
      job
      |> Job.put_result(stored_result)
      |> Job.put_error(message)

    with {:ok, transitioned} <-
           Job.transition(
             job,
             "outcome_unknown"
           ),
         {:ok, stored} <-
           Jobs.complete_approval(transitioned) do
      {:ok, stored}
    end
  end

  defp reconcile_approval(
         %Job{
           status: status
         },
         _approval_id,
         _reason
       ) do
    {:error,
     {
       :job_not_waiting_approval,
       status
     }}
  end

  defp approval_reconciliation_code({
         :approval_service_failed,
         {
           :request_failed,
           _reason
         }
       }),
       do: "approval_transport_ambiguous"

  defp approval_reconciliation_code({
         :approval_service_failed,
         {
           :ai_service_error,
           _status,
           _body
         }
       }),
       do: "approval_service_response_ambiguous"

  defp approval_reconciliation_code({
         :approval_service_failed,
         {
           :invalid_approval_result,
           _result
         }
       }),
       do: "approval_result_invalid"

  defp approval_reconciliation_code({
         :invalid_approval_outcome,
         _reason
       }),
       do: "approval_contract_invalid"

  defp approval_reconciliation_code({
         :approval_id_mismatch,
         _expected,
         _actual
       }),
       do: "approval_id_mismatch"

  defp approval_reconciliation_code(_reason),
    do: "approval_outcome_unresolved"

  defp complete_approved_job(
         %Job{status: "waiting_approval"} = job,
         approval_outcome
       )
       when is_map(approval_outcome) do
    previous_result =
      if is_map(job.result), do: job.result, else: %{}

    target_status =
      if WorkflowContinuation.verified_terminal?(job, approval_outcome),
        do: ApprovalOutcome.target_job_status(approval_outcome),
        else: "outcome_unknown"

    message =
      if target_status == "outcome_unknown" and
           approval_outcome["execution_status"] == "succeeded",
         do:
           "Jira creation has no verified provider read-back. Do not repeat the action; trusted reconciliation is required.",
         else: ApprovalOutcome.message(approval_outcome)

    stored_result =
      previous_result
      |> Map.put("approval_execution", approval_outcome)
      |> put_approval_answer(target_status, approval_outcome, message)

    stored_result =
      if get_in(previous_result, ["workflow", "state"]) == "awaiting_ticket_approval" do
        stored_result
        |> Map.put(
          "approval_history",
          Map.get(previous_result, "approval_history", []) ++
            [%{"proposal" => job.proposed_tool, "execution" => approval_outcome}]
        )
        |> Map.put("workflow", Map.put(previous_result["workflow"], "state", target_status))
      else
        stored_result
      end

    job = Job.put_result(job, stored_result)

    job =
      if target_status in ["failed", "denied", "outcome_unknown"] do
        Job.put_error(
          job,
          message || "Approved action did not complete successfully."
        )
      else
        job
      end

    with {:ok, transitioned} <- Job.transition(job, target_status),
         {:ok, stored} <- Jobs.complete_approval(transitioned) do
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
