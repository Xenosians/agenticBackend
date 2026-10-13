defmodule ItsmBackendWeb.ExtensionController do
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract
  alias ItsmBackendWeb.AuthRequest
  alias ItsmBackend.RuntimeConfig

  request_contract(:index, [])
  request_contract(:command, required_body: ["action", "payload"])

  def index(conn, _params), do: authenticated(conn, "list", %{}, false)

  def command(conn, %{"action" => action, "payload" => payload}) when is_map(payload) do
    authenticated(conn, action, payload, true)
  end

  def command(conn, _), do: conn |> put_status(422) |> json(%{error: "invalid_extension_request"})

  defp authenticated(conn, action, payload, csrf?) do
    case AuthRequest.require_authenticated(conn, csrf: csrf?) do
      {:ok, conn, ctx} ->
        config = RuntimeConfig.ai_service!()
        # Identity is derived exclusively from the authenticated Phoenix session.
        case Req.post("#{config.base_url}/internal/v1/extensions",
               headers: [{"x-internal-token", RuntimeConfig.internal_job_token!()}],
               json: %{owner: ctx.user["user_id"], action: action, payload: payload},
               retry: false,
               receive_timeout: 130_000
             ) do
          {:ok, %{status: 200, body: body}} when is_map(body) ->
            json(conn, body)

          {:ok, %{status: 422}} ->
            conn |> put_status(422) |> json(%{error: "extension_request_rejected"})

          _ ->
            conn |> put_status(503) |> json(%{error: "extension_service_unavailable"})
        end

      {:error, conn} ->
        conn
    end
  end
end
