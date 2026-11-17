defmodule ItsmBackendWeb.TailnetController do
  use ItsmBackendWeb, :controller

  use ItsmBackendWeb.RequestContract

  request_contract(:overview, [])

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.AuthRequest

  # Read-only: the signed-in owner sees each tailnet device's health and the
  # tailnet's DNS settings exactly as the AI read them, from the account's own
  # Tailscale link (else the machine default). Nothing is changed.
  def overview(conn, _params) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} ->
        ai_client = RuntimeConfig.ai_client!()

        if function_exported?(ai_client, :tailnet_overview, 1) do
          case ai_client.tailnet_overview(ctx.user["user_id"]) do
            {:ok, body} when is_map(body) ->
              json(conn, body)

            {:error, {:ai_service_error, 503, %{"error" => "tailnet_not_configured"}}} ->
              conn |> put_status(:service_unavailable) |> json(%{error: "tailnet_not_configured"})

            {:error, {:ai_service_error, 502, %{"error" => "tailnet_read_failed"} = body}} ->
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
       do: %{error: "tailnet_read_failed", reason: reason, message: String.slice(message, 0, 300)},
       else: %{error: "tailnet_read_failed"}
  end

  defp unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: "tailnet_unavailable"})
  end
end
