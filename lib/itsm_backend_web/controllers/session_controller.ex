defmodule ItsmBackendWeb.SessionController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.Auth
  alias ItsmBackendWeb.AuthRequest

  def index(conn, _params) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} ->
        case Auth.list_sessions(ctx.user["user_id"], ctx.session["session_id"]) do
          {:ok, sessions} -> json(conn, %{sessions: sessions})
          {:error, _} -> conn |> put_status(:internal_server_error) |> json(%{error: "session_lookup_failed"})
        end
      {:error, conn} -> conn
    end
  end

  def revoke(conn, %{"id" => session_id}) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} ->
        case Auth.revoke_session(ctx.user["user_id"], session_id) do
          {:ok, nil} -> conn |> put_status(:not_found) |> json(%{error: "session_not_found"})
          {:ok, _} -> json(conn, %{status: "revoked", session_id: session_id})
          {:error, _} -> conn |> put_status(:internal_server_error) |> json(%{error: "session_revoke_failed"})
        end
      {:error, conn} -> conn
    end
  end
end
