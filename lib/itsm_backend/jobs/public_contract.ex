defmodule ItsmBackend.Jobs.PublicContract do
  @moduledoc """
  Contract enforcement for the public durable job API.

  This module owns public job wire-format validation and construction.

  Durable lifecycle semantics remain owned by the Jobs domain.
  """

  alias ItsmBackend.Contracts

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
end
