defmodule ItsmBackend.AIClient.HTTP do
  @behaviour ItsmBackend.AIClient

  defp base_url do
    Application.fetch_env!(
      :itsm_backend,
      :ai_service_url
    )
  end

  @impl true
  def run(user_id, message) do
    case Req.post(
           "#{base_url()}/v1/agent/run",
           json: %{
             user_id: user_id,
             message: message
           },
           receive_timeout: 300_000
         ) do
      {:ok, %{status: status, body: body}}
      when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:ai_service_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def approve(approval_id) do
    case Req.post(
           "#{base_url()}/v1/approvals/#{approval_id}/approve"
         ) do
      {:ok, %{status: status, body: body}}
      when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:ai_service_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def health do
    case Req.get(
           "#{base_url()}/health"
         ) do
      {:ok, %{status: status, body: body}}
      when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:ai_service_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end
end
