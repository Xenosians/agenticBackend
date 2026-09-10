defmodule ItsmBackend.AIClient.JobContract do
  @moduledoc """
  Contract enforcement for the durable Phoenix-to-AI execution
  handshake.

  JSON Schema validates the wire structure.

  This module additionally validates semantic correlation between
  the request Phoenix sent and the acknowledgement returned by AI.
  """

  alias ItsmBackend.Contracts

  # ------------------------------------------------------------
  # Execute request
  # ------------------------------------------------------------

  @spec build_execute_request(
          term(),
          term(),
          term(),
          term()
        ) ::
          {:ok, map()}
          | {:error,
             {
               :invalid_ai_job_execute_request,
               term()
             }}
  def build_execute_request(
        job_id,
        attempt,
        user_id,
        message
      ) do
    payload = %{
      "job_id" => job_id,
      "attempt" => attempt,
      "user_id" => user_id,
      "message" => message
    }

    case Contracts.validate(
           :ai_job_execute_request,
           payload
         ) do
      :ok ->
        {:ok, payload}

      {:error, reason} ->
        {:error,
         {
           :invalid_ai_job_execute_request,
           reason
         }}
    end
  end

  # ------------------------------------------------------------
  # Execute acknowledgement
  # ------------------------------------------------------------

  @spec validate_accepted(
          String.t(),
          pos_integer(),
          term()
        ) ::
          {:ok, map()}
          | {:error, term()}
  def validate_accepted(
        expected_job_id,
        expected_attempt,
        body
      )
      when is_binary(expected_job_id) and
             is_integer(expected_attempt) and
             expected_attempt > 0 and
             is_map(body) do
    with :ok <-
           validate_ack_contract(body),
         :ok <-
           validate_job_id(
             expected_job_id,
             body
           ),
         :ok <-
           validate_attempt(
             expected_attempt,
             body
           ) do
      {:ok, body}
    end
  end

  def validate_accepted(
        expected_job_id,
        expected_attempt,
        body
      ) do
    {:error,
     {
       :invalid_ai_job_ack,
       :invalid_validation_input,
       expected_job_id,
       expected_attempt,
       body
     }}
  end

  # ------------------------------------------------------------
  # Schema validation
  # ------------------------------------------------------------

  defp validate_ack_contract(body) do
    case Contracts.validate(
           :ai_job_accepted,
           body
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         {
           :invalid_ai_job_ack,
           :contract_violation,
           reason
         }}
    end
  end

  # ------------------------------------------------------------
  # Correlation validation
  # ------------------------------------------------------------

  defp validate_job_id(
         expected_job_id,
         %{
           "job_id" => expected_job_id
         }
       ) do
    :ok
  end

  defp validate_job_id(
         expected_job_id,
         %{
           "job_id" => actual_job_id
         }
       ) do
    {:error,
     {
       :invalid_ai_job_ack,
       :job_id_mismatch,
       expected_job_id,
       actual_job_id
     }}
  end

  defp validate_attempt(
         expected_attempt,
         %{
           "attempt" => expected_attempt
         }
       ) do
    :ok
  end

  defp validate_attempt(
         expected_attempt,
         %{
           "attempt" => actual_attempt
         }
       ) do
    {:error,
     {
       :invalid_ai_job_ack,
       :attempt_mismatch,
       expected_attempt,
       actual_attempt
     }}
  end
end
