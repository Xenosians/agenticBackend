defmodule ItsmBackendWeb.ProxmoxController do
  use ItsmBackendWeb, :controller

  use ItsmBackendWeb.RequestContract

  request_contract(:overview, [])
  request_contract(:health, [])

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.AuthRequest

  def overview(conn, _params), do: read(conn, :proxmox_overview)

  # Backups and each node's physical disks: read separately from the overview
  # because they list backup storages and run SMART on every node.
  def health(conn, _params), do: read(conn, :proxmox_health)

  defp read(conn, callback) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} ->
        ai_client = RuntimeConfig.ai_client!()

        # The AI reads the signed-in account's own Proxmox link (else the
        # machine default); the account comes only from the session.
        if function_exported?(ai_client, callback, 1) do
          case apply(ai_client, callback, [ctx.user["user_id"]]) do
            {:ok, body} when is_map(body) ->
              json(conn, body)

            {:error, {:ai_service_error, 503, %{"error" => code}}}
            when code in ["proxmox_not_configured", "proxmox_configuration_invalid"] ->
              conn |> put_status(:service_unavailable) |> json(%{error: code})

            {:error, {:ai_service_error, 502, %{"error" => "proxmox_read_failed"} = body}} ->
              conn |> put_status(:service_unavailable) |> json(read_failure(body))

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

  # The AI names why a read failed with a stable code and a fixed message
  # (never provider text); only those two bounded fields cross to the browser.
  defp read_failure(body) do
    reason = body["reason"]
    message = body["message"]

    if is_binary(reason) and Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, reason) and
         is_binary(message),
       do: %{error: "proxmox_read_failed", reason: reason, message: String.slice(message, 0, 300)},
       else: %{error: "proxmox_read_failed"}
  end

  defp unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: "proxmox_dashboard_unavailable"})
  end
end
