defmodule ItsmBackend.AIClient.HTTP do
  @behaviour ItsmBackend.AIClient

  alias ItsmBackend.AIClient.JobContract
  alias ItsmBackend.RuntimeConfig

  # ------------------------------------------------------------
  # Transitional synchronous execution
  # ------------------------------------------------------------

  @impl true
  def run(
        user_id,
        message
      ) do
    config =
      RuntimeConfig.ai_service!()

    case Req.post(
           "#{config.base_url}/v1/agent/run",
           headers: [{"x-internal-token", RuntimeConfig.internal_job_token!()}],
           json: %{
             user_id: user_id,
             message: message
           },
           receive_timeout: config.run_timeout_ms
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
  def execute_job(job_id, attempt, user_id, message) do
    execute_job(job_id, attempt, user_id, message, [])
  end

  @impl true
  def execute_job(
        job_id,
        attempt,
        user_id,
        message,
        context
      ) do
    with {:ok, payload} <-
           JobContract.build_execute_request(
             job_id,
             attempt,
             user_id,
             message,
             context
           ) do
      execute_validated_job(job_id, attempt, payload)
    end
  end

  defp execute_validated_job(
         job_id,
         attempt,
         payload
       ) do
    config =
      RuntimeConfig.ai_service!()

    case Req.post(
           "#{config.base_url}/v1/jobs/execute",
           headers: [{"x-internal-token", RuntimeConfig.internal_job_token!()}],
           json: payload,
           receive_timeout: config.execute_timeout_ms
         ) do
      {:ok,
       %{
         status: 202,
         body: body
       }} ->
        JobContract.validate_accepted(
          job_id,
          attempt,
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
    approval_decision(approval_id, "approve")
  end

  @impl true
  def reject(approval_id) do
    approval_decision(approval_id, "reject")
  end

  defp approval_decision(approval_id, decision) do
    config =
      RuntimeConfig.ai_service!()

    case Req.post(
           "#{config.base_url}/v1/approvals/#{URI.encode_www_form(approval_id)}/#{decision}",
           headers: [{"x-internal-token", RuntimeConfig.internal_job_token!()}],
           receive_timeout: config.run_timeout_ms,
           retry: false
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
  # Integration status
  # ------------------------------------------------------------

  @impl true
  def integrations do
    config = RuntimeConfig.ai_service!()

    case Req.get(
           "#{config.base_url}/v1/integrations",
           receive_timeout: config.health_timeout_ms
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:ai_service_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # ------------------------------------------------------------
  # Health
  # ------------------------------------------------------------

  @impl true
  def health do
    config =
      RuntimeConfig.ai_service!()

    case Req.get(
           "#{config.base_url}/health",
           receive_timeout: config.health_timeout_ms
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
    config =
      RuntimeConfig.ai_service!()

    case Req.get(
           "#{config.base_url}/ready",
           receive_timeout: config.ready_timeout_ms
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
end
