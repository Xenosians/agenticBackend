defmodule ItsmBackend.Jobs.Lifecycle do
  @moduledoc "Versioned lifecycle projection. Legacy storage remains readable; retries are never inferred."
  def wire_status("denied", 1), do: "failed"
  def wire_status("outcome_unknown", 1), do: "reconciliation_required"
  def wire_status("reconciliation_required", 2), do: "outcome_unknown"
  def wire_status(status, version) when version in [1, 2], do: status
  def versioned(payload, 1), do: payload
  def versioned(payload, 2), do: Map.put(payload, "contract_version", 2)
end
