defmodule ItsmBackend.ProxmoxActions do
  @moduledoc """
  Proxmox guest power actions started from the dashboard.

  A button press becomes one governed proposal: the AI service runs the same
  gateway a chat request uses (owner tool switches, grounding, trusted policy
  that freezes the guest's type and name) and returns one pending approval.
  Phoenix keeps the action for the owner and lets only that owner decide it.

  Each decision is claimed in storage before the AI is called, so a repeat or
  concurrent decision never runs the action twice. An approval whose outcome
  could not be confirmed stays `outcome_unknown` and is never re-sent; the
  guest is checked instead. The AI approval id never leaves Phoenix.
  """

  require Logger

  alias ItsmBackend.ProxmoxActions.SurrealStore
  alias ItsmBackend.RuntimeConfig

  @actions ~w(start shutdown reboot force_stop)
  @node ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
  @submission ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @action_id ~r/\A[0-9a-f]{32}\z/
  @approval_id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @list_limit 50
  @receipt_fields ~w(observed_status expected_status upid task_exit_status verification_ok observed_at)

  @doc "Proposes one action; the same submission returns the same saved action."
  def propose(user, params) when is_map(params) do
    with {:ok, input} <- validate(params) do
      action_id = action_id(user["user_id"], input.submission_id)

      case SurrealStore.get(action_id) do
        {:ok, nil} -> create(user, action_id, input)
        {:ok, existing} -> replay(existing, input)
        {:error, reason} -> {:error, {:storage_failed, reason}}
      end
    end
  end

  def propose(_user, _params), do: {:error, :invalid_proxmox_action}

  @doc "The owner's recent actions, newest first."
  def list(user) do
    with {:ok, actions} <- SurrealStore.list_for_user(user["user_id"], @list_limit) do
      {:ok, Enum.map(actions, &public/1)}
    end
  end

  @doc "Approves the owner's pending action once and records its receipt."
  def approve(user, action_id), do: decide(user, action_id, :approve)

  @doc "Rejects the owner's pending action; nothing runs."
  def reject(user, action_id), do: decide(user, action_id, :reject)

  defp create(user, action_id, input) do
    client = RuntimeConfig.ai_client!()

    if function_exported?(client, :proxmox_propose, 4) do
      case client.proxmox_propose(user["user_id"], input.node, input.vmid, input.action) do
        {:ok, %{"status" => "approval_required", "approval_id" => approval_id} = proposal}
        when is_binary(approval_id) ->
          if Regex.match?(@approval_id, approval_id) and proposal["node"] == input.node and
               proposal["vmid"] == input.vmid and proposal["action"] == input.action,
             do: save(user, action_id, input, proposal),
             else: {:error, :proxmox_action_unavailable}

        {:error,
         {:ai_service_error, status, %{"detail" => %{"code" => code, "message" => message}}}}
        when status in [403, 409, 503] and is_binary(code) and is_binary(message) ->
          {:error, {:refused, status, code, String.slice(message, 0, 300)}}

        other ->
          Logger.warning("proxmox proposal failed: #{inspect(other, limit: 5)}")
          {:error, :proxmox_action_unavailable}
      end
    else
      {:error, :proxmox_action_unavailable}
    end
  end

  defp save(user, action_id, input, proposal) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    record = %{
      "action_id" => action_id,
      "submission_id" => input.submission_id,
      "user_id" => user["user_id"],
      "approval_id" => proposal["approval_id"],
      "action" => input.action,
      "node" => input.node,
      "vmid" => input.vmid,
      "type" => proposal["type"],
      "name" => proposal["name"],
      "risk" => proposal["risk"],
      "approval_text" => String.slice(to_string(proposal["approval_text"]), 0, 600),
      "status" => "waiting_approval",
      "created_at" => now,
      "decided_at" => nil,
      "receipt" => nil,
      "error" => nil
    }

    case SurrealStore.create_idempotent(record) do
      {:ok, stored, created} -> {:ok, public(stored), created}
      {:error, :proxmox_action_conflict} -> {:error, :proxmox_action_conflict}
      {:error, reason} -> {:error, {:storage_failed, reason}}
    end
  end

  defp replay(existing, input) do
    if {existing["node"], existing["vmid"], existing["action"]} ==
         {input.node, input.vmid, input.action},
       do: {:ok, public(existing), :existing},
       else: {:error, :proxmox_action_conflict}
  end

  defp decide(user, action_id, decision) do
    with true <-
           (is_binary(action_id) and Regex.match?(@action_id, action_id)) || {:error, :not_found},
         {:ok, action} when is_map(action) <- SurrealStore.get(action_id),
         true <- action["user_id"] == user["user_id"] || {:error, :not_found} do
      claim_and_decide(action, decision)
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, {:storage_failed, reason}}
    end
  end

  defp claim_and_decide(%{"status" => "waiting_approval"} = action, decision) do
    claimed_status = if decision == :approve, do: "executing", else: "rejecting"

    case SurrealStore.transition(action["action_id"], "waiting_approval", claimed_status, %{}) do
      {:ok, claimed} -> call_ai(claimed, decision)
      {:error, :stale} -> settled(action["action_id"], decision)
      {:error, reason} -> {:error, {:storage_failed, reason}}
    end
  end

  defp claim_and_decide(action, decision), do: settled_answer(action, decision)

  defp settled(action_id, decision) do
    case SurrealStore.get(action_id) do
      {:ok, action} when is_map(action) -> settled_answer(action, decision)
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, {:storage_failed, reason}}
    end
  end

  # A repeated decision returns the stored one; the opposite decision is refused.
  defp settled_answer(action, decision) do
    approved = action["status"] in ~w(executing succeeded failed outcome_unknown)

    cond do
      decision == :approve and approved -> {:ok, public(action)}
      decision == :reject and action["status"] in ~w(rejecting rejected) -> {:ok, public(action)}
      true -> {:error, :already_decided}
    end
  end

  defp call_ai(action, decision) do
    client = RuntimeConfig.ai_client!()
    answer = apply(client, decision, [action["approval_id"]])
    {status, receipt, error} = outcome(decision, answer)

    fields = %{
      "receipt" => receipt,
      "error" => error,
      "decided_at" =>
        DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    }

    case SurrealStore.transition(action["action_id"], action["status"], status, fields) do
      {:ok, stored} ->
        {:ok, public(stored)}

      {:error, reason} ->
        Logger.error("proxmox action outcome not recorded: #{inspect(reason)}")
        {:ok, public(Map.merge(action, Map.put(fields, "status", status)))}
    end
  end

  defp outcome(:approve, {:ok, %{"execution_status" => "succeeded", "result" => result}})
       when is_map(result) do
    if result["verification_ok"] == true,
      do: {"succeeded", Map.take(result, @receipt_fields), nil},
      else:
        {"outcome_unknown", Map.take(result, @receipt_fields),
         "The action finished without a read-back."}
  end

  defp outcome(:approve, {:ok, %{"execution_status" => "failed"} = body}),
    do: {"failed", receipt_of(body), error_of(body, "The action failed.")}

  defp outcome(:approve, {:ok, %{"execution_status" => "rejected"} = body}),
    do: {"rejected", nil, error_of(body, "The approval was already closed.")}

  defp outcome(:approve, {:ok, body}),
    do:
      {"outcome_unknown", receipt_of(body),
       error_of(body, "The action outcome is not confirmed.")}

  defp outcome(:approve, _error),
    do:
      {"outcome_unknown", nil,
       "The AI service did not confirm the outcome. Check the guest before trying again."}

  defp outcome(:reject, {:ok, %{"execution_status" => "rejected"}}),
    do: {"rejected", nil, nil}

  defp outcome(:reject, {:ok, %{"execution_status" => "succeeded"} = body}),
    do: {"succeeded", receipt_of(body), nil}

  defp outcome(:reject, {:ok, body}),
    do:
      {"outcome_unknown", receipt_of(body),
       error_of(body, "The approval was already being executed.")}

  defp outcome(:reject, _error),
    do: {"outcome_unknown", nil, "The AI service did not confirm the rejection."}

  defp receipt_of(%{"result" => result}) when is_map(result),
    do: Map.take(result, @receipt_fields)

  defp receipt_of(_body), do: nil

  defp error_of(body, fallback) do
    case body do
      %{"result" => %{"error" => message}} when is_binary(message) ->
        String.slice(message, 0, 300)

      %{"error" => message} when is_binary(message) ->
        String.slice(message, 0, 300)

      _ ->
        fallback
    end
  end

  defp validate(params) do
    with %{"node" => node, "vmid" => vmid, "action" => action, "submission_id" => submission}
         when is_binary(node) and is_integer(vmid) and is_binary(action) and is_binary(submission) <-
           params,
         true <- Regex.match?(@node, node),
         true <- vmid >= 1 and vmid <= 999_999_999,
         true <- action in @actions,
         true <- Regex.match?(@submission, submission) do
      {:ok, %{node: node, vmid: vmid, action: action, submission_id: submission}}
    else
      _ -> {:error, :invalid_proxmox_action}
    end
  end

  defp action_id(owner, submission_id) do
    :crypto.hash(:sha256, Jason.encode!(["proxmox-action-v1", owner, submission_id]))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  # The approval id and owner stay inside Phoenix; the receipt is flattened.
  defp public(action) do
    receipt = if is_map(action["receipt"]), do: action["receipt"], else: %{}

    action
    |> Map.take(
      ~w(action_id action node vmid type name risk approval_text status created_at decided_at error)
    )
    |> Map.merge(Map.take(receipt, @receipt_fields))
  end
end
