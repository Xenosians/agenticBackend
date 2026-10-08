defmodule ItsmBackend.Jobs.ApprovalOutcome do
  @moduledoc """
  Typed boundary contract for AI approval execution outcomes.

  Transport success and side-effect success are independent:

    * protocol_status == "processed" means Phoenix received a valid
      durable approval outcome from AI.
    * execution_status says what happened to the approved action.

  Deterministic mapping:

    succeeded  -> completed
    failed     -> failed
    unresolved -> reconciliation_required

  An unresolved outcome is never automatically retried because the
  external side effect may already have occurred.
  """

  @execution_statuses [
    "succeeded",
    "failed",
    "unresolved"
  ]

  @status_pairs %{
    "succeeded" => "approved",
    "failed" => "failed",
    "unresolved" => "executing"
  }

  @spec normalize(term()) :: {:ok, map()} | {:error, term()}
  def normalize(payload) when is_map(payload) do
    with {:ok, approval_id} <- required_string(payload, "approval_id"),
         {:ok, protocol_status} <- required_string(payload, "protocol_status"),
         :ok <- require_processed(protocol_status),
         {:ok, execution_status} <- required_execution_status(payload),
         {:ok, approval_status} <- required_string(payload, "approval_status"),
         :ok <- require_matching_authority_state(execution_status, approval_status),
         {:ok, replayed} <- required_boolean(payload, "replayed"),
         {:ok, result} <- optional_map(payload, "result"),
         {:ok, error} <- optional_string(payload, "error") do
      {:ok,
       %{
         "approval_id" => approval_id,
         "protocol_status" => protocol_status,
         "execution_status" => execution_status,
         "approval_status" => approval_status,
         "replayed" => replayed,
         "result" => result,
         "error" => error
       }}
    else
      {:error, reason} ->
        {:error, {:invalid_approval_outcome, reason}}
    end
  end

  def normalize(payload) do
    {:error, {:invalid_approval_outcome, {:invalid_payload, payload}}}
  end

  @spec target_job_status(map()) :: String.t()
  def target_job_status(%{"execution_status" => "succeeded"}), do: "completed"
  def target_job_status(%{"execution_status" => "failed"}), do: "failed"

  def target_job_status(%{"execution_status" => "unresolved"}),
    do: "reconciliation_required"

  @spec message(map()) :: String.t() | nil
  def message(%{"execution_status" => "succeeded"}), do: nil

  def message(%{"execution_status" => "failed"} = outcome) do
    outcome["error"] ||
      nested_error(outcome["result"]) ||
      "Approved action execution failed."
  end

  def message(%{"execution_status" => "unresolved"} = outcome) do
    outcome["error"] ||
      nested_error(outcome["result"]) ||
      "Approved action outcome is unresolved. Automatic retry is disabled; trusted reconciliation is required."
  end

  defp require_processed("processed"), do: :ok

  defp require_processed(value),
    do: {:error, {:invalid_protocol_status, value}}

  defp required_execution_status(payload) do
    with {:ok, value} <- required_string(payload, "execution_status") do
      if value in @execution_statuses,
        do: {:ok, value},
        else: {:error, {:invalid_execution_status, value}}
    end
  end

  defp require_matching_authority_state(execution_status, approval_status) do
    expected = Map.fetch!(@status_pairs, execution_status)

    if approval_status == expected,
      do: :ok,
      else: {:error, {:authority_state_mismatch, execution_status, approval_status, expected}}
  end

  defp required_string(payload, key) do
    case fetch(payload, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, {:empty_string, key}}, else: {:ok, value}

      value ->
        {:error, {:invalid_string, key, value}}
    end
  end

  defp required_boolean(payload, key) do
    case fetch(payload, key) do
      value when is_boolean(value) -> {:ok, value}
      value -> {:error, {:invalid_boolean, key, value}}
    end
  end

  defp optional_map(payload, key) do
    case fetch(payload, key) do
      nil -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      value -> {:error, {:invalid_optional_map, key, value}}
    end
  end

  defp optional_string(payload, key) do
    case fetch(payload, key) do
      nil -> {:ok, nil}
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:ok, nil}, else: {:ok, value}

      value ->
        {:error, {:invalid_optional_string, key, value}}
    end
  end

  defp nested_error(value) when is_map(value) do
    fetch(value, "error") || fetch(value, "message")
  end

  defp nested_error(_), do: nil

  defp fetch(payload, key) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    Map.get(payload, key, if(atom_key, do: Map.get(payload, atom_key), else: nil))
  end
end
