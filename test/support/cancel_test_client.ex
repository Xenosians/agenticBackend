defmodule ItsmBackendWeb.CancelTestClient do
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
  defdelegate approve(approval_id), to: ItsmBackend.AIClient.Mock
  @impl true
  defdelegate reject(approval_id), to: ItsmBackend.AIClient.Mock

  @impl true
  def cancel_job(job_id, attempt) do
    send(self(), {:ai_cancel, job_id, attempt})

    Process.get(
      :ai_cancel_result,
      {:ok, %{"job_id" => job_id, "attempt" => attempt, "status" => "stopping"}}
    )
  end
end
