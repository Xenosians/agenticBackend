defmodule ItsmBackend.AIClient.Mock do
  @behaviour ItsmBackend.AIClient

  @impl true
  def run(user_id, message) do
    cond do
      String.contains?(
        String.downcase(message),
        "unlock"
      ) ->
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

      String.contains?(
        String.downcase(message),
        "locked"
      ) ->
        {:ok,
         %{
           request_id: "req-mock-001",
           status: "success",
           routes: [
             "account-specialist"
           ],
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
  def execute_job(
        job_id,
        _attempt,
        _user_id,
        _message
      ) do
    {:ok,
     %{
       "job_id" => job_id,
       "status" => "accepted",
       "duplicate" => false
     }}
  end

  @impl true
  def approve(approval_id) do
    {:ok,
     %{
       "approval_id" => approval_id,
       "protocol_status" => "processed",
       "execution_status" => "succeeded",
       "approval_status" => "approved",
       "replayed" => false,
       "result" => %{
         "ok" => true,
         "status" => "success"
       },
       "error" => nil
     }}
  end

  @impl true
  def reject(approval_id) do
    {:ok,
     %{
       "approval_id" => approval_id,
       "protocol_status" => "processed",
       "execution_status" => "rejected",
       "approval_status" => "rejected",
       "replayed" => false,
       "result" => nil,
       "error" => "Action rejected by the user. No tool was executed."
     }}
  end

  @impl true
  def integrations do
    # Shape of the AI service's provider setup readiness (configuration only).
    {:ok,
     %{
       "integrations" => [
         %{
           "id" => "openwrt",
           "name" => "OpenWrt",
           "kind" => "provider",
           "state" => "not_configured",
           "configured" => false,
           "missing" => ["OPENWRT_BASE_URL", "OPENWRT_USERNAME", "OPENWRT_PASSWORD"],
           "capabilities" => [],
           "mode" => "read_only",
           "host" => nil,
           "verify_tls" => true
         }
       ]
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

  @impl true
  def ready do
    {:ok,
     %{
       status: "ready",
       service: "mock_ai"
     }}
  end
end
