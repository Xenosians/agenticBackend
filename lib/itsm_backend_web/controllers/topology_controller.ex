defmodule ItsmBackendWeb.TopologyController do
  @moduledoc """
  Saved topologies and their drift checks for the signed-in owner (FR-093).
  Every change and check needs CSRF for cookie sessions; another owner's
  topology is reported exactly like a missing one.
  """
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  require Logger

  alias ItsmBackend.{Engineering, Topologies}
  alias ItsmBackendWeb.{AuthRequest, PublicError}

  request_contract(:index, [])
  request_contract(:show, [])
  request_contract(:create, required_body: ["name", "design", "layout"])
  request_contract(:update, required_body: ["name", "design", "layout", "base_version"])
  request_contract(:delete, [])
  request_contract(:drift, required_body: ["version"])

  def index(conn, _params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      case Topologies.list(ctx.user) do
        {:ok, topologies} -> json(conn, %{topologies: topologies})
        {:error, reason} -> unavailable(conn, reason)
      end
    else
      {:error, conn} -> conn
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      respond(conn, Topologies.get(ctx.user, id), :ok)
    else
      {:error, conn} -> conn
    end
  end

  def create(conn, params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      respond(
        conn,
        Topologies.create(ctx.user, Map.take(params, ~w(name design layout))),
        :created
      )
    else
      {:error, conn} -> conn
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      input = Map.take(params, ~w(name design layout base_version))
      respond(conn, Topologies.update(ctx.user, id, input), :ok)
    else
      {:error, conn} -> conn
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      case Topologies.archive(ctx.user, id) do
        :ok -> json(conn, %{archived: true, topology_id: id})
        error -> respond(conn, error, :ok)
      end
    else
      {:error, conn} -> conn
    end
  end

  def drift(conn, %{"id" => id} = params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      case Topologies.for_drift(ctx.user, id, params["version"]) do
        {:ok, topology} -> report(conn, Engineering.drift(topology))
        error -> respond(conn, error, :ok)
      end
    else
      {:error, conn} -> conn
    end
  end

  def report(conn, {:ok, report}), do: json(conn, report)

  def report(conn, {:refused, code}),
    do:
      PublicError.render(
        conn,
        :unprocessable_entity,
        code,
        "The engineering check refused this input. Review it and try again."
      )

  def report(conn, {:error, reason}) do
    Logger.error("engineering read failed: #{inspect(reason, limit: 5)}")

    PublicError.render(
      conn,
      :service_unavailable,
      "engineering_unavailable",
      "The engineering check could not be completed. Try again.",
      retryable: true
    )
  end

  defp respond(conn, {:ok, topology}, status),
    do: conn |> put_status(status) |> json(%{topology: topology})

  defp respond(conn, {:error, :not_found}, _status),
    do:
      PublicError.render(conn, :not_found, "topology_not_found", "This topology does not exist.")

  defp respond(conn, {:error, :invalid_topology}, _status) do
    PublicError.render(
      conn,
      :unprocessable_entity,
      "invalid_topology",
      "Check the topology's name, nodes, connections and canvas positions."
    )
  end

  defp respond(conn, {:error, :private_content}, _status) do
    PublicError.render(
      conn,
      :unprocessable_entity,
      "private_topology_content",
      "Topologies cannot hold credentials or personal data."
    )
  end

  defp respond(conn, {:error, :version_conflict}, _status) do
    PublicError.render(
      conn,
      :conflict,
      "topology_version_conflict",
      "This topology changed since you opened it. Reload it before saving or checking."
    )
  end

  defp respond(conn, {:error, reason}, _status), do: unavailable(conn, reason)

  defp unavailable(conn, reason) do
    Logger.error("topology request failed: #{inspect(reason, limit: 5)}")

    PublicError.render(
      conn,
      :service_unavailable,
      "topology_unavailable",
      "The topology could not be confirmed. Reload before trying again.",
      retryable: true
    )
  end
end
