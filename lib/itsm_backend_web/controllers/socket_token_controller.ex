defmodule ItsmBackendWeb.SocketTokenController do
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  request_contract(:create, [])

  alias ItsmBackendWeb.AuthRequest
  alias ItsmBackendWeb.SocketAuth

  def create(conn, _params) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, context} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(SocketAuth.issue(context.user, context.session))

      {:error, conn} ->
        conn
    end
  end
end
