defmodule ItsmBackend.Engineering.PublicContract do
  @moduledoc """
  Validates engineering receipts from the AI service before forwarding them.

  A drift report must describe exactly the requested topology version, stay
  "simulated" and keep execution disabled. A netlist report must claim no
  actuation. Anything else is treated as an unavailable service, never shown.
  """

  @digest ~r/\A[0-9a-f]{64}\z/
  @node_statuses ~w(matches drifted missing unknown)
  @source_states ~w(observed unavailable not_configured)
  @drift_keys ~w(schema state_kind topology_id topology_version observed_at observation_sha256 sources nodes counts potentially_affected not_in_design execution_enabled apply_to_live notes)
  @netlist_keys ~w(schema state_kind actuation format tool sha256 summary components nets findings findings_truncated)

  def valid_drift?(report, topology_id, version) do
    exact?(report, @drift_keys) and report["schema"] == "topology-drift.v1" and
      report["state_kind"] == "simulated" and report["topology_id"] == topology_id and
      report["topology_version"] === version and report["execution_enabled"] === false and
      report["apply_to_live"] === false and is_binary(report["observed_at"]) and
      digest?(report["observation_sha256"]) and list_of?(report["sources"], &source?/1) and
      list_of?(report["nodes"], &node?/1) and counts?(report["counts"]) and
      list_of?(report["potentially_affected"], &is_binary/1) and
      list_of?(report["not_in_design"], &is_binary/1) and list_of?(report["notes"], &is_binary/1)
  end

  def valid_netlist?(report) do
    exact?(report, @netlist_keys) and report["schema"] == "pcb-netlist-inspection.v1" and
      report["state_kind"] == "desired" and report["actuation"] == "none" and
      report["format"] == "kicad" and digest?(report["sha256"]) and is_map(report["summary"]) and
      is_list(report["components"]) and is_list(report["nets"]) and is_list(report["findings"]) and
      is_boolean(report["findings_truncated"])
  end

  defp source?(%{"id" => id, "state" => state, "error_code" => code} = row)
       when map_size(row) == 3,
       do: is_binary(id) and state in @source_states and (is_nil(code) or is_binary(code))

  defp source?(_), do: false

  defp node?(%{"id" => id, "status" => status, "differences" => differences} = row)
       when map_size(row) in [3, 4],
       do:
         is_binary(id) and status in @node_statuses and is_list(differences) and
           (map_size(row) == 3 or is_binary(row["reason"]))

  defp node?(_), do: false

  defp counts?(counts) do
    exact?(counts, @node_statuses) and
      Enum.all?(counts, fn {_status, count} -> is_integer(count) and count >= 0 end)
  end

  defp exact?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  defp digest?(value), do: is_binary(value) and Regex.match?(@digest, value)
  defp list_of?(value, check), do: is_list(value) and Enum.all?(value, check)
end
