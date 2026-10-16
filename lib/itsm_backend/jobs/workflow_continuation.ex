defmodule ItsmBackend.Jobs.WorkflowContinuation do
  @moduledoc "Validates the bounded, separately approved account-to-Jira continuation."
  alias ItsmBackend.Jobs.Job

  def resolve(%Job{} = job, outcome, nil) do
    if get_in(job.result || %{}, ["workflow", "state"]) == "awaiting_account_approval" and
         outcome["execution_status"] == "succeeded" do
      {:error, :workflow_continuation_missing}
    else
      :none
    end
  end

  def resolve(%Job{} = job, outcome, continuation) when is_map(continuation) do
    workflow = get_in(job.result || %{}, ["workflow"]) || %{}
    proposal = job.proposed_tool || %{}

    with true <- workflow["kind"] == "account_ticket",
         true <-
           Enum.sort(Map.keys(continuation)) == [
             "error",
             "kind",
             "proposed_tool",
             "result",
             "source_approval_id",
             "status"
           ],
         true <- workflow["state"] == "awaiting_account_approval",
         true <- proposal["tool"] == "account_create",
         true <- continuation["kind"] == "account_ticket",
         true <- continuation["source_approval_id"] == proposal["approval_id"],
         true <- workflow["source_approval_id"] == proposal["approval_id"],
         true <- outcome["execution_status"] == "succeeded" do
      resolve_bound(job, outcome, continuation)
    else
      _ -> {:error, :workflow_continuation_invalid}
    end
  end

  def resolve(_, _, _), do: {:error, :workflow_continuation_invalid}

  defp resolve_bound(job, outcome, %{"status" => "waiting_approval"} = continuation) do
    next = continuation["proposed_tool"]
    result = continuation["result"]
    account = outcome["result"] || %{}

    with true <- verified_account?(account),
         true <- continuation["error"] == nil,
         true <-
           is_map(next) and Enum.sort(Map.keys(next)) == ["approval_id", "arguments", "tool"],
         true <- next["tool"] == "ticket_create" and is_map(next["arguments"]),
         true <-
           is_binary(next["approval_id"]) and next["approval_id"] != "" and
             next["approval_id"] != outcome["approval_id"],
         true <- is_map(result) and result["status"] == "approval_required",
         %{
           "kind" => "account_ticket",
           "state" => "awaiting_ticket_approval",
           "source_approval_id" => source,
           "account" => identity
         } <- result["workflow"],
         true <- source == outcome["approval_id"],
         true <- identity == Map.take(account, ["user_id", "email"]),
         [worker] <- result["results"],
         true <-
           worker["status"] == "approval_required" and worker["proposed_tool"] == "ticket_create",
         true <-
           worker["approval_id"] == next["approval_id"] and
             worker["proposed_arguments"] == next["arguments"],
         [agent] <- result["routes"],
         true <- is_binary(agent) and agent != "" and worker["agent_name"] == agent do
      stored =
        result
        |> Map.put("approval_history", approval_history(job, outcome))
        |> Map.put("approval_execution", outcome)

      {:ok, %{job | proposed_tool: next, selected_agent: agent, result: stored, error: nil}}
    else
      _ -> {:error, :workflow_continuation_invalid}
    end
  end

  defp resolve_bound(job, outcome, %{"status" => status} = continuation)
       when status in ["failed", "outcome_unknown"] do
    if continuation["proposed_tool"] == nil and is_binary(continuation["error"]) do
      result =
        (job.result || %{})
        |> Map.put("approval_execution", outcome)
        |> Map.put("approval_history", approval_history(job, outcome))
        |> Map.put("answer", continuation["error"])
        |> Map.put("workflow", Map.merge(job.result["workflow"], %{"state" => status}))

      with {:ok, updated} <- Job.transition(Job.put_result(job, result), status) do
        {:ok, Job.put_error(updated, continuation["error"])}
      end
    else
      {:error, :workflow_continuation_invalid}
    end
  end

  defp resolve_bound(_, _, _), do: {:error, :workflow_continuation_invalid}

  defp verified_account?(result) do
    result["ok"] == true and result["status"] in ["success", "executed"] and
      result["operation"] == "account_create" and result["account_created"] == true and
      result["verification_ok"] == true and result["credential_persisted"] == true and
      is_binary(result["user_id"]) and result["user_id"] != "" and
      is_binary(result["email"]) and result["email"] != ""
  end

  defp approval_history(job, outcome) do
    (Map.get(job.result || %{}, "approval_history", []) || []) ++
      [%{"proposal" => job.proposed_tool, "execution" => outcome}]
  end

  def verified_terminal?(job, outcome) do
    if get_in(job.result || %{}, ["workflow", "state"]) == "awaiting_ticket_approval" and
         outcome["execution_status"] == "succeeded" do
      result = outcome["result"] || %{}

      arguments = (job.proposed_tool || %{})["arguments"] || %{}
      project = arguments["expected_project_key"] || arguments["project_key"]
      project = if is_binary(project), do: String.upcase(project), else: nil

      result["ok"] == true and result["provider"] == "jira" and
        result["status"] in ["success", "executed"] and
        result["operation"] == "create_ticket" and result["verification_ok"] == true and
        result["mutation_performed"] == true and is_binary(project) and
        is_binary(result["ticket_key"]) and
        Regex.match?(~r/\A[A-Z][A-Z0-9_]*-[0-9]+\z/, result["ticket_key"]) and
        String.starts_with?(result["ticket_key"], project <> "-") and
        result["new_value"] == job.proposed_tool["arguments"]["summary"]
    else
      true
    end
  end
end
