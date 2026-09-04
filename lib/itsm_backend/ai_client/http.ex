defmodule ItsmBackend.AIClient.HTTP do
  @behaviour ItsmBackend.AIClient

  # ------------------------------------------------------------
  # Configuration
  # ------------------------------------------------------------

  defp base_url do
    Application.fetch_env!(
      :itsm_backend,
      :ai_service_url
    )
  end

  # ------------------------------------------------------------
  # Transitional synchronous execution
  # ------------------------------------------------------------

  @impl true
  def run(
        user_id,
        message
      ) do
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
        {:error,
         {
           :ai_service_error,
           status,
           body
         }}

      {:error, reason} ->
        {:error,
         {
           :request_failed,
           reason
         }}
    end
  end

  # ------------------------------------------------------------
  # Durable async job execution
  # Handshake #1
  # ------------------------------------------------------------

  @impl true
  def execute_job(
        job_id,
        attempt,
        user_id,
        message
      ) do
    case Req.post(
           "#{base_url()}/v1/jobs/execute",
           json: %{
             job_id: job_id,
             attempt: attempt,
             user_id: user_id,
             message: message
           },
           receive_timeout: 10_000
         ) do
      {:ok,
       %{
         status: 202,
         body: body
       }} ->
        validate_job_ack(
          job_id,
          body
        )

      {:ok,
       %{
         status: status,
         body: body
       }}
      when status in 200..299 ->
        {:error,
         {
           :unexpected_ai_ack,
           status,
           body
         }}

      {:ok,
       %{
         status: status,
         body: body
       }} ->
        {:error,
         {
           :ai_service_error,
           status,
           body
         }}

      {:error, reason} ->
        {:error,
         {
           :request_failed,
           reason
         }}
    end
  end

  # ------------------------------------------------------------
  # Approval
  # ------------------------------------------------------------

  @impl true
  def approve(approval_id) do
    case Req.post("#{base_url()}/v1/approvals/#{approval_id}/approve") do
      {:ok, %{status: status, body: body}}
      when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error,
         {
           :ai_service_error,
           status,
           body
         }}

      {:error, reason} ->
        {:error,
         {
           :request_failed,
           reason
         }}
    end
  end

  # ------------------------------------------------------------
  # Health
  # ------------------------------------------------------------

  @impl true
  def health do
    case Req.get(
           "#{base_url()}/health",
           receive_timeout: 5_000
         ) do
      {:ok, %{status: status, body: body}}
      when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error,
         {
           :ai_service_error,
           status,
           body
         }}

      {:error, reason} ->
        {:error,
         {
           :request_failed,
           reason
         }}
    end
  end

  # ------------------------------------------------------------
  # Readiness
  # ------------------------------------------------------------

  @impl true
  def ready do
    case Req.get(
           "#{base_url()}/ready",
           receive_timeout: 5_000
         ) do
      {:ok, %{status: status, body: body}}
      when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error,
         {
           :ai_service_error,
           status,
           body
         }}

      {:error, reason} ->
        {:error,
         {
           :request_failed,
           reason
         }}
    end
  end

  # ------------------------------------------------------------
  # Job ACK validation
  # ------------------------------------------------------------

  defp validate_job_ack(
         expected_job_id,
         %{
           "job_id" => actual_job_id,
           "status" => "accepted"
         } = body
       )
       when actual_job_id == expected_job_id do
    {:ok, body}
  end

  defp validate_job_ack(
         expected_job_id,
         body
       ) do
    {:error,
     {
       :invalid_job_ack,
       expected_job_id,
       body
     }}
  end
end
