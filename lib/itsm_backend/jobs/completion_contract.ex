defmodule ItsmBackend.Jobs.CompletionContract do
  @moduledoc """
  Contract enforcement for durable AI-to-Phoenix completion
  callbacks and Phoenix-to-AI completion acknowledgements.

  The outer completion envelope is validated against the canonical
  completion schema.

  A non-null proposed tool is additionally validated against the
  canonical tool-proposal contract.

  Completion acknowledgements are constructed and validated here
  before being returned to the AI completion outbox.
  """

  alias ItsmBackend.Contracts

  # ------------------------------------------------------------
  # AI -> Phoenix completion
  # ------------------------------------------------------------

  @spec validate(term()) ::
          {:ok, map()}
          | {:error, term()}
  def validate(payload)
      when is_map(payload) do
    with :ok <-
           validate_completion_envelope(payload),
         :ok <-
           validate_proposed_tool(
             Map.get(
               payload,
               "proposed_tool"
             )
           ) do
      {:ok, payload}
    end
  end

  def validate(payload) do
    {:error,
     {
       :invalid_ai_job_completion,
       :invalid_payload_type,
       payload
     }}
  end

  # ------------------------------------------------------------
  # Phoenix -> AI completion acknowledgement
  # ------------------------------------------------------------

  @spec build_ack(
          term(),
          term(),
          term()
        ) ::
          {:ok, map()}
          | {:error, term()}
  def build_ack(
        job_id,
        status,
        disposition
      ) do
    with {:ok, acknowledgement} <-
           acknowledgement_value(disposition) do
      payload = %{
        "job_id" => job_id,
        "status" => status,
        "acknowledgement" => acknowledgement
      }

      validate_ack(payload)
    end
  end

  # ------------------------------------------------------------
  # Completion envelope
  # ------------------------------------------------------------

  defp validate_completion_envelope(payload) do
    case Contracts.validate(
           :ai_job_completion,
           payload
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         {
           :invalid_ai_job_completion,
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
           :invalid_ai_job_completion,
           :tool_proposal_contract_violation,
           reason
         }}
    end
  end

  defp validate_proposed_tool(proposed_tool) do
    {:error,
     {
       :invalid_ai_job_completion,
       :invalid_tool_proposal,
       proposed_tool
     }}
  end

  # ------------------------------------------------------------
  # Completion acknowledgement
  # ------------------------------------------------------------

  defp validate_ack(payload) do
    case Contracts.validate(
           :ai_job_completion_ack,
           payload
         ) do
      :ok ->
        {:ok, payload}

      {:error, reason} ->
        {:error,
         {
           :invalid_ai_job_completion_ack,
           :contract_violation,
           reason
         }}
    end
  end

  defp acknowledgement_value(:applied) do
    {:ok, "applied"}
  end

  defp acknowledgement_value(:duplicate) do
    {:ok, "duplicate"}
  end

  defp acknowledgement_value(disposition) do
    {:error,
     {
       :invalid_ai_job_completion_ack,
       :invalid_disposition,
       disposition
     }}
  end
end
