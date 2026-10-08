defmodule ItsmBackendWeb.IntegrationController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.AuthRequest

  def index(conn, _params) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, _ctx} ->
        ai_client = RuntimeConfig.ai_client!()

        case ai_client.integrations() do
          {:ok, body} when is_map(body) ->
            json(conn, body)

          {:error, _reason} ->
            conn
            |> put_status(:service_unavailable)
            |> json(%{error: "integration_status_unavailable"})
        end

      {:error, conn} ->
        conn
    end
  rescue
    _error ->
      conn
      |> put_status(:service_unavailable)
      |> json(%{error: "integration_status_unavailable"})
  end
end
