defmodule ItsmBackend.Jobs.PublicContract do
  @moduledoc """
  Contract enforcement for the public durable job API.

  This module owns public job wire-format validation and
  construction.

  Durable lifecycle semantics remain owned by the Jobs domain.

  Tool-specific result semantics do not belong here. A job result
  is transported as structured application data and may contain
  nested machine-readable tool results and presentation metadata.
  """

  alias ItsmBackend.Contracts
  alias ItsmBackend.Jobs.Job

  # ------------------------------------------------------------
  # Create request
  # ------------------------------------------------------------

  @spec validate_create_request(term()) ::
          {:ok, map()}
          | {:error, term()}
  def validate_create_request(payload)
      when is_map(payload) do
    case Contracts.validate(
           :job_create_request,
           payload
         ) do
      :ok ->
        {:ok, payload}

      {:error, reason} ->
        {:error,
         {
           :invalid_job_create_request,
           :contract_violation,
           reason
         }}
    end
  end

  def validate_create_request(payload) do
    {:error,
     {
       :invalid_job_create_request,
       :invalid_payload_type,
       payload
     }}
  end

  # ------------------------------------------------------------
  # Create response
  # ------------------------------------------------------------

  @spec build_create_response(
          term(),
          term()
        ) ::
          {:ok, map()}
          | {:error, term()}
  def build_create_response(
        job_id,
        status
      ) do
    payload = %{
      "job_id" => job_id,
      "status" => status
    }

    case Contracts.validate(
           :job_create_response,
           payload
         ) do
      :ok ->
        {:ok, payload}

      {:error, reason} ->
        {:error,
         {
           :invalid_job_create_response,
           :contract_violation,
           reason
         }}
    end
  end

  # ------------------------------------------------------------
  # Durable job response
  # ------------------------------------------------------------

  @spec build_job_response(Job.t()) ::
          {:ok, map()}
          | {:error, term()}
  def build_job_response(%Job{} = job) do
    payload = %{
      "job_id" => job.id,
      "user_id" => job.user_id,
      "conversation_id" => job.conversation_id,
      "chat_id" => job.conversation_id,
      "message" => job.message,
      "status" => job.status,
      "attempts" => job.attempts,
      "created_at" => encode_datetime(job.created_at),
      "claimed_at" => encode_datetime(job.claimed_at),
      "lease_expires_at" => encode_datetime(job.lease_expires_at),
      "completed_at" => encode_datetime(job.completed_at),
      "selected_agent" => job.selected_agent,
      "proposed_tool" => job.proposed_tool,
      "result" => job.result,
      "error" => job.error
    }

    with :ok <-
           validate_job_response_envelope(payload),
         :ok <-
           validate_proposed_tool(job.proposed_tool) do
      {:ok, payload}
    end
  end

  def build_job_response(value) do
    {:error,
     {
       :invalid_job_response,
       :invalid_job,
       value
     }}
  end

  # ------------------------------------------------------------
  # Public response validation
  # ------------------------------------------------------------

  defp validate_job_response_envelope(payload) do
    case Contracts.validate(
           :job_response,
           payload
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         {
           :invalid_job_response,
           :contract_violation,
           reason
         }}
    end
  end

  # ------------------------------------------------------------
  # Nested tool proposal
  # ------------------------------------------------------------

  defp validate_proposed_tool(nil) do
    :ok
  end

  defp validate_proposed_tool(proposed_tool)
       when is_map(proposed_tool) do
    case Contracts.validate(
           :tool_proposal,
           proposed_tool
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         {
           :invalid_job_response,
           :tool_proposal_contract_violation,
           reason
         }}
    end
  end

  defp validate_proposed_tool(proposed_tool) do
    {:error,
     {
       :invalid_job_response,
       :invalid_tool_proposal,
       proposed_tool
     }}
  end

  # ------------------------------------------------------------
  # Wire-format helpers
  # ------------------------------------------------------------

  defp encode_datetime(nil) do
    nil
  end

  defp encode_datetime(%DateTime{} = datetime) do
    DateTime.to_iso8601(datetime)
  end

  defp encode_datetime(value) do
    value
  end
end
