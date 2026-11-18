defmodule ItsmBackend.ProxmoxActions do
  @moduledoc """
  Proxmox guest actions started from the dashboard.

  A button press becomes one governed proposal: the AI service runs the same
  gateway a chat request uses (owner tool switches, grounding, trusted policy
  that freezes the guest's type and name and, when the owner named no VMID,
  asks Proxmox for the next free one) and returns one pending approval.
  Phoenix keeps the action for the owner and lets only that owner decide it.

  A destructive action (delete, snapshot delete, rollback, restore) also needs
  the target's exact name typed by the owner. Phoenix checks it against the
  name frozen in its own record before anything is sent, and the AI approval
  authority checks it again; a missing or wrong name leaves the action waiting
  and nothing runs.

  Each decision is claimed in storage before the AI is called, so a repeat or
  concurrent decision never runs the action twice. An approval whose outcome
  could not be confirmed stays `outcome_unknown` and is never re-sent; the
  guest is checked instead. The AI approval id never leaves Phoenix.
  """

  require Logger

  alias ItsmBackend.ProxmoxActions.SurrealStore
  alias ItsmBackend.RuntimeConfig

  @power_actions ~w(start shutdown reboot force_stop)
  # A restore and a container create make a new guest, so no source VMID is
  # required; the AI asks Proxmox for a free one unless the owner named it.
  @new_guest_actions ~w(create backup_restore)
  @destructive ~w(delete snapshot_delete snapshot_rollback backup_restore)
  # What each dashboard change carries beyond the exact target. The AI's
  # trusted policy validates the values again; here only their shape is
  # checked so nothing arbitrary is forwarded.
  @changes %{
    "set_resources" => %{optional: ~w(cores memory_mib), min_fields: 1},
    "resize_disk" => %{required: ~w(disk grow_gib)},
    "set_options" => %{optional: ~w(tags on_boot), min_fields: 1},
    "snapshot_create" => %{required: ~w(snapshot), optional: ~w(description)},
    "snapshot_delete" => %{required: ~w(snapshot)},
    "snapshot_rollback" => %{required: ~w(snapshot)},
    "backup_now" => %{required: ~w(storage), optional: ~w(mode)},
    "backup_restore" => %{required: ~w(volume name), optional: ~w(newid storage pool)},
    "clone" => %{required: ~w(name full), optional: ~w(newid pool)},
    "create" => %{
      required: ~w(hostname template cores memory_mib disk_gib storage),
      optional: ~w(newid pool description)
    },
    "delete" => %{}
  }
  @actions @power_actions ++ Map.keys(@changes)
  @integers ~w(cores memory_mib disk_gib grow_gib newid)
  @booleans ~w(on_boot full)
  @node ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
  @submission ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @action_id ~r/\A[0-9a-f]{32}\z/
  @approval_id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @list_limit 50
  @receipt_fields ~w(observed_status expected_status upid task_exit_status verification_ok observed_at
                     changed retry_safe previous observed tags on_boot snapshot deleted new_backups
                     storage previous_bytes new_bytes)

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
  def approve(user, action_id, confirm_name \\ nil),
    do: decide(user, action_id, :approve, confirm_name)

  @doc "Rejects the owner's pending action; nothing runs."
  def reject(user, action_id), do: decide(user, action_id, :reject, nil)

  defp create(user, action_id, input) do
    client = RuntimeConfig.ai_client!()

    if function_exported?(client, :proxmox_propose, 2) do
      proposal = %{node: input.node, vmid: input.vmid, action: input.action, params: input.params}

      case client.proxmox_propose(user["user_id"], proposal) do
        {:ok, %{"status" => "approval_required", "approval_id" => approval_id} = proposal}
        when is_binary(approval_id) ->
          if Regex.match?(@approval_id, approval_id) and proposal["node"] == input.node and
               proposal["action"] == input.action and target_matches?(proposal, input),
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

  # The AI answers with the guest it froze: the named one, or the guest the
  # change creates. Anything else is not the approved target.
  defp target_matches?(proposal, input) do
    if is_nil(input.vmid),
      do: is_integer(proposal["vmid"]) and proposal["vmid"] >= 1,
      else: proposal["vmid"] == input.vmid
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
      "vmid" => input.vmid || proposal["vmid"],
      "new_vmid" => proposal["new_vmid"],
      "params" => input.params,
      "destructive" => input.destructive,
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
    requested = %{
      "action" => input.action,
      "node" => input.node,
      "vmid" => input.vmid,
      "params" => input.params
    }

    if SurrealStore.same_binding?(existing, requested),
      do: {:ok, public(existing), :existing},
      else: {:error, :proxmox_action_conflict}
  end

  defp decide(user, action_id, decision, confirm_name) do
    with true <-
           (is_binary(action_id) and Regex.match?(@action_id, action_id)) || {:error, :not_found},
         {:ok, action} when is_map(action) <- SurrealStore.get(action_id),
         true <- action["user_id"] == user["user_id"] || {:error, :not_found},
         {:ok, confirm_name} <- confirmed(action, decision, confirm_name) do
      claim_and_decide(action, decision, confirm_name)
    else
      {:ok, nil} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} when reason in [:confirmation_required, :confirmation_mismatch] ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:storage_failed, reason}}
    end
  end

  # The owner's typed target name, checked against the name frozen in this
  # record before the decision is claimed. The AI authority checks it again.
  defp confirmed(_action, :reject, _typed), do: {:ok, nil}

  defp confirmed(%{"destructive" => true, "name" => name}, :approve, typed) do
    cond do
      not is_binary(typed) or typed == "" -> {:error, :confirmation_required}
      typed != name -> {:error, :confirmation_mismatch}
      true -> {:ok, typed}
    end
  end

  defp confirmed(_action, :approve, _typed), do: {:ok, nil}

  defp claim_and_decide(%{"status" => "waiting_approval"} = action, decision, confirm_name) do
    claimed_status = if decision == :approve, do: "executing", else: "rejecting"

    case SurrealStore.transition(action["action_id"], "waiting_approval", claimed_status, %{}) do
      {:ok, claimed} -> call_ai(claimed, decision, confirm_name)
      {:error, :stale} -> settled(action["action_id"], decision)
      {:error, reason} -> {:error, {:storage_failed, reason}}
    end
  end

  defp claim_and_decide(action, decision, _confirm_name), do: settled_answer(action, decision)

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

  defp call_ai(action, decision, confirm_name) do
    client = RuntimeConfig.ai_client!()

    answer =
      case decision do
        :approve -> client.approve(action["approval_id"], confirm_name)
        :reject -> client.reject(action["approval_id"])
      end

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
         "The change finished without a read-back."}
  end

  defp outcome(:approve, {:ok, %{"execution_status" => "failed"} = body}),
    do: {"failed", receipt_of(body), error_of(body, "The action failed.")}

  defp outcome(:approve, {:ok, %{"execution_status" => "rejected"} = body}),
    do: {"rejected", nil, error_of(body, "The approval was already closed.")}

  # The AI approval authority refused the typed name. Nothing ran; the action
  # goes back to waiting so the owner can read the reason and try again.
  defp outcome(
         :approve,
         {:error,
          {:ai_service_error, 409, %{"detail" => %{"code" => code, "message" => message}}}}
       )
       when code in ~w(confirmation_required confirmation_mismatch) do
    {"waiting_approval", nil, String.slice(to_string(message), 0, 300)}
  end

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
    with %{
           "node" => node,
           "action" => action,
           "submission_id" => submission
         } <- params,
         true <- is_binary(node) and is_binary(action) and is_binary(submission),
         true <- Regex.match?(@node, node),
         true <- action in @actions,
         true <- Regex.match?(@submission, submission),
         {:ok, vmid} <- target_vmid(action, Map.get(params, "vmid")),
         {:ok, fields} <- change_fields(action, params) do
      {:ok,
       %{
         node: node,
         vmid: vmid,
         action: action,
         params: fields,
         destructive: action in @destructive,
         submission_id: submission
       }}
    else
      _ -> {:error, :invalid_proxmox_action}
    end
  end

  defp target_vmid(action, nil) when action in @new_guest_actions, do: {:ok, nil}

  defp target_vmid(_action, vmid) when is_integer(vmid) and vmid >= 1 and vmid <= 999_999_999,
    do: {:ok, vmid}

  defp target_vmid(_action, _vmid), do: {:error, :invalid_proxmox_action}

  defp change_fields(action, _params) when action in @power_actions, do: {:ok, %{}}

  defp change_fields(action, params) do
    spec = Map.fetch!(@changes, action)
    required = Map.get(spec, :required, [])
    allowed = required ++ Map.get(spec, :optional, [])

    fields =
      allowed
      |> Map.new(fn key -> {key, Map.get(params, key)} end)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    cond do
      Enum.any?(required, &(not Map.has_key?(fields, &1))) -> {:error, :invalid_proxmox_action}
      map_size(fields) < Map.get(spec, :min_fields, 0) -> {:error, :invalid_proxmox_action}
      Enum.all?(fields, &valid_field?/1) -> {:ok, fields}
      true -> {:error, :invalid_proxmox_action}
    end
  end

  defp valid_field?({key, value}) when key in @integers, do: is_integer(value) and value >= 1
  defp valid_field?({key, value}) when key in @booleans, do: is_boolean(value)
  defp valid_field?({_key, value}) when is_binary(value), do: byte_size(value) <= 256
  defp valid_field?(_field), do: false

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
      ~w(action_id action node vmid new_vmid type name risk approval_text status created_at
         decided_at error)
    )
    |> Map.put("destructive", action["destructive"] == true)
    |> Map.merge(Map.take(receipt, @receipt_fields))
  end
end
