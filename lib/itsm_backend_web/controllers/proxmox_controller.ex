defmodule ItsmBackendWeb.ProxmoxController do
  use ItsmBackendWeb, :controller

  use ItsmBackendWeb.RequestContract

  request_contract(:overview, [])

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.AuthRequest

  def overview(conn, _params) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, _ctx} ->
        ai_client = RuntimeConfig.ai_client!()

        if function_exported?(ai_client, :proxmox_overview, 0) do
          case ai_client.proxmox_overview() do
            {:ok, body} when is_map(body) ->
              json(conn, body)

            {:error, {:ai_service_error, 503, %{"error" => code}}}
            when code in ["proxmox_not_configured", "proxmox_configuration_invalid"] ->
              conn |> put_status(:service_unavailable) |> json(%{error: code})

            {:error, {:ai_service_error, 502, %{"error" => "proxmox_read_failed"}}} ->
              conn |> put_status(:service_unavailable) |> json(%{error: "proxmox_read_failed"})

            _error ->
              unavailable(conn)
          end
        else
          unavailable(conn)
        end

      {:error, conn} ->
        conn
    end
  rescue
    _error -> unavailable(conn)
  end

  defp unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: "proxmox_dashboard_unavailable"})
  end
end
