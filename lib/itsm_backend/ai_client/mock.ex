defmodule ItsmBackend.AIClient.Mock do
  @behaviour ItsmBackend.AIClient

  @impl true
  def run(user_id, message) do
    cond do
      String.contains?(String.downcase(message), "unlock") ->
        {:ok,
         %{
           request_id: "req-mock-002",
           status: "approval_required",
           approval_id: "approval-mock-001",
           tool: "unlock_user",
           arguments: %{
             user_id: user_id
           }
         }}

      String.contains?(String.downcase(message), "locked") ->
        {:ok,
         %{
           request_id: "req-mock-001",
           status: "success",
           routes: ["account-specialist"],
           result: %{
             user_id: user_id,
             locked: false
           }
         }}

      true ->
        {:error, :unsupported_request}
    end
  end

  @impl true
  def approve(approval_id) do
    {:ok,
     %{
       approval_id: approval_id,
       status: "executed",
       result: %{
         ok: true
       }
     }}
  end

  @impl true
  def health do
    {:ok,
     %{
       status: "ok",
       service: "mock_ai"
     }}
  end
end
