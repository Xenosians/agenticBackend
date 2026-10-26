defmodule ItsmBackendWeb.SessionController do
  use ItsmBackendWeb, :controller

  use ItsmBackendWeb.RequestContract

  request_contract(:index, [])
  request_contract(:revoke, [])
  request_contract(:revoke_others, [])

  alias ItsmBackend.Auth
  alias ItsmBackendWeb.AuthRequest
  alias ItsmBackendWeb.PublicError

  def revoke_others(conn, params) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} ->
        case if(map_size(params) == 0,
               do: Auth.revoke_other_sessions(ctx.user["user_id"], ctx.session["session_id"]),
               else: {:error, :invalid_request}
             ) do
          {:ok, count} ->
            json(conn, %{status: "revoked", revoked_count: count})

          {:error, :invalid_request} ->
            PublicError.render(
              conn,
              :unprocessable_entity,
              "invalid_request",
              "This action takes no arguments."
            )

          {:error, _} ->
            PublicError.render(
              conn,
              :service_unavailable,
              "session_revoke_unconfirmed",
              "Other sessions could not be confirmed as ended. Reload the session list before trying again.",
              retryable: true
            )
        end

      {:error, conn} ->
        conn
    end
  end

  def index(conn, _params) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} ->
        case Auth.list_sessions(ctx.user["user_id"], ctx.session["session_id"]) do
          {:ok, sessions} ->
            json(conn, %{sessions: sessions})

          {:error, _} ->
            conn |> put_status(:internal_server_error) |> json(%{error: "session_lookup_failed"})
        end

      {:error, conn} ->
        conn
    end
  end

  def revoke(conn, %{"id" => session_id}) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} ->
        case Auth.revoke_session(ctx.user["user_id"], session_id) do
          {:ok, nil} ->
            conn |> put_status(:not_found) |> json(%{error: "session_not_found"})

          {:ok, _} ->
            json(conn, %{status: "revoked", session_id: session_id})

          {:error, _} ->
            conn |> put_status(:internal_server_error) |> json(%{error: "session_revoke_failed"})
        end

      {:error, conn} ->
        conn
    end
  end
end
