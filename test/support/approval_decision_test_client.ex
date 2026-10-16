defmodule ItsmBackendWeb.ApprovalDecisionTestClient do
  @moduledoc false
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
  def approve(approval_id), do: decision(:approve, approval_id)

  @impl true
  def reject(approval_id), do: decision(:reject, approval_id)

  defp decision(action, approval_id) do
    send(self(), {:ai_approval_decision, action, approval_id})

    case Process.get(:approval_decision_result) do
      nil -> apply(ItsmBackend.AIClient.Mock, action, [approval_id])
      callback when is_function(callback, 1) -> callback.(approval_id)
      result -> result
    end
  end
end
