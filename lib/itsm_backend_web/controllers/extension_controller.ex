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

          {:ok, %{status: 422, body: body}} ->
            detail =
              case body do
                %{"detail" => value} -> public_extension_detail(value)
                _ -> public_extension_detail(nil)
              end

            conn
            |> put_status(422)
            |> json(%{
              error: "extension_request_rejected",
              detail: detail
            })

          _ ->
            conn |> put_status(503) |> json(%{error: "extension_service_unavailable"})
        end

      {:error, conn} ->
        conn
    end
  end

  # Only a tiny, explicitly-shaped diagnostic contract is allowed to cross
  # the Phoenix public boundary. Never proxy an arbitrary upstream body.
  defp public_extension_detail(%{"code" => code, "message" => message} = detail)
       when is_binary(code) and is_binary(message) do
    result = %{
      code: String.slice(code, 0, 80),
      message: String.slice(message, 0, 300)
    }

    case Map.get(detail, "provider_status") do
      status when is_integer(status) and status >= 100 and status <= 599 ->
        Map.put(result, :provider_status, status)

      _ ->
        result
    end
  end

  defp public_extension_detail(message) when is_binary(message) do
    %{
      code: "extension_request_rejected",
      message: String.slice(message, 0, 300)
    }
  end

  defp public_extension_detail(_) do
    %{
      code: "extension_request_rejected",
      message: "Extension request rejected."
    }
  end
end
