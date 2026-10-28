defmodule ItsmBackendWeb.EngineeringController do
  @moduledoc """
  PCB netlist inspection for the signed-in owner (FR-093). Only the text is
  forwarded; inspection reads a design and never drives hardware.
  """
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  alias ItsmBackend.Engineering
  alias ItsmBackendWeb.{AuthRequest, TopologyController}

  request_contract(:netlist, required_body: ["netlist"])

  def netlist(conn, params) do
    with {:ok, conn, _ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      TopologyController.report(conn, Engineering.inspect_netlist(params["netlist"]))
    else
      {:error, conn} -> conn
    end
  end
end
