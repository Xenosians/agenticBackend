defmodule ItsmBackendWeb.EngineeringProbePlug do
  @moduledoc false
  import Plug.Conn

  # Stands in for the AI service: records each engineering request for the test
  # process and answers with the response the test chose for that path.
  # `:echo_drift` answers with a valid drift report for the requested version.
  def init(options), do: options

  def call(conn, {test_pid, responses}) do
    {:ok, body, conn} = read_body(conn)
    request = Jason.decode!(body)

    send(
      test_pid,
      {:engineering_request, conn.request_path, request, get_req_header(conn, "x-internal-token")}
    )

    {status, response} =
      case Agent.get(responses, &Map.fetch!(&1, conn.request_path)) do
        {status, :echo_drift} ->
          {status, drift_report(request["topology_id"], request["version"])}

        chosen ->
          chosen
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(response))
  end

  @doc "A valid drift receipt for one topology version."
  def drift_report(topology_id, version) do
    %{
      "schema" => "topology-drift.v1",
      "state_kind" => "simulated",
      "topology_id" => topology_id,
      "topology_version" => version,
      "observed_at" => "2026-10-29T01:00:00+00:00",
      "observation_sha256" => String.duplicate("a", 64),
      "sources" => [%{"id" => "containers", "state" => "observed", "error_code" => nil}],
      "nodes" => [
        %{"id" => "container:itsm-surrealdb", "status" => "matches", "differences" => []},
        %{
          "id" => "endpoint:phoenix",
          "status" => "unknown",
          "reason" => "source_unavailable",
          "differences" => []
        }
      ],
      "counts" => %{"matches" => 1, "drifted" => 0, "missing" => 0, "unknown" => 1},
      "potentially_affected" => [],
      "not_in_design" => [],
      "execution_enabled" => false,
      "apply_to_live" => false,
      "notes" => ["Only properties the topology declares are compared."]
    }
  end
end
