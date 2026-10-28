defmodule ItsmBackend.Engineering do
  @moduledoc """
  Engineering reads through the AI service (SRS 1.9 FR-093, V19-09).

  Phoenix sends one exact saved topology version, or netlist text, and checks
  the receipt before anyone sees it. The owner always comes from the session;
  no provider, URL or path crosses this boundary.
  """

  alias ItsmBackend.Engineering.PublicContract
  alias ItsmBackend.RuntimeConfig

  @drift_path "/internal/v1/engineering/topology/drift"
  @netlist_path "/internal/v1/engineering/netlist"
  # AI refusal codes that are safe and useful to show the owner.
  @public_refusals ~w(invalid_topology private_topology_content invalid_netlist invalid_engineering_request)
  @netlist_limit 2_000_000

  def drift(topology) do
    body = %{
      "topology_id" => topology["topology_id"],
      "version" => topology["version"],
      "topology" => topology["design"]
    }

    with {:ok, report} <- forward(@drift_path, body),
         true <-
           PublicContract.valid_drift?(report, topology["topology_id"], topology["version"]) ||
             {:error, :invalid_receipt} do
      {:ok, report}
    end
  end

  def inspect_netlist(text) when is_binary(text) and byte_size(text) in 1..@netlist_limit do
    with {:ok, report} <- forward(@netlist_path, %{"netlist" => text}),
         true <- PublicContract.valid_netlist?(report) || {:error, :invalid_receipt} do
      {:ok, report}
    end
  end

  def inspect_netlist(_), do: {:refused, "invalid_netlist"}

  defp forward(path, body) do
    config = RuntimeConfig.ai_service!()

    case Req.post("#{config.base_url}#{path}",
           headers: [{"x-internal-token", RuntimeConfig.internal_job_token!()}],
           json: body,
           retry: false,
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: report}} when is_map(report) ->
        {:ok, report}

      {:ok, %{status: 422, body: %{"detail" => code}}} when code in @public_refusals ->
        {:refused, code}

      {:ok, %{status: 422}} ->
        {:refused, "invalid_engineering_request"}

      _ ->
        {:error, :unavailable}
    end
  end
end
