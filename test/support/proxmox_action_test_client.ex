defmodule ItsmBackendWeb.ProxmoxActionTestClient do
  @moduledoc false
  # Answers like the AI service for the Proxmox dashboard. Each test sets the
  # proposal and decision answers in its process; every call is reported back.
  @behaviour ItsmBackend.AIClient

  @impl true
  defdelegate run(user_id, message), to: ItsmBackend.AIClient.Mock
  @impl true
  defdelegate execute_job(job_id, attempt, user_id, message), to: ItsmBackend.AIClient.Mock
  @impl true
  defdelegate health(), to: ItsmBackend.AIClient.Mock
  @impl true
  defdelegate ready(), to: ItsmBackend.AIClient.Mock
  @impl true
  defdelegate integrations(), to: ItsmBackend.AIClient.Mock

  @impl true
  def proxmox_overview(_owner) do
    case Application.get_env(:itsm_backend, :proxmox_test_overview) do
      nil -> {:error, :proxmox_dashboard_unavailable}
      answer -> answer
    end
  end

  @impl true
  def proxmox_propose(owner, node, vmid, action) do
    notify({:proxmox_propose, owner, node, vmid, action})
    answer(:proxmox_test_propose, {:error, :unsupported_request})
  end

  @impl true
  def approve(approval_id) do
    notify({:ai_approval_decision, :approve, approval_id})
    answer(:proxmox_test_approve, {:error, :unsupported_request})
  end

  @impl true
  def reject(approval_id) do
    notify({:ai_approval_decision, :reject, approval_id})
    answer(:proxmox_test_reject, {:error, :unsupported_request})
  end

  defp notify(message) do
    case Application.get_env(:itsm_backend, :proxmox_test_listener) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp answer(key, default) do
    case Application.get_env(:itsm_backend, key) do
      nil -> default
      callback when is_function(callback, 0) -> callback.()
      result -> result
    end
  end
end
