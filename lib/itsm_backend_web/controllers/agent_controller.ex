defmodule ItsmBackendWeb.AgentController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.AuthRequest

  def run(conn, %{"message" => message}) when is_binary(message) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} ->
        case RuntimeConfig.ai_client!().run(ctx.user["user_id"], message) do
          {:ok, result} ->
            json(conn, result)

          {:error, :unsupported_request} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{status: "error", error: "unsupported_request"})

          {:error, reason} ->
            conn |> put_status(:bad_gateway) |> json(%{status: "error", error: inspect(reason)})
        end

      {:error, conn} ->
        conn
    end
  end

  def run(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{status: "error", error: "message is required"})
  end
end
