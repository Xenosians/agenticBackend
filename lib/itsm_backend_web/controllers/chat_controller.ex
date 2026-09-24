defmodule ItsmBackendWeb.ChatController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.Chats
  alias ItsmBackendWeb.AuthRequest

  def create(conn, params) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} ->
        case Chats.create(ctx.user, params) do
          {:ok, chat} -> conn |> put_status(:created) |> json(%{chat: chat})
          {:error, _} -> conn |> put_status(:internal_server_error) |> json(%{error: "chat_create_failed"})
        end
      {:error, conn} -> conn
    end
  end

  def index(conn, _params) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} ->
        case Chats.list(ctx.user) do
          {:ok, chats} -> json(conn, %{chats: chats})
          {:error, _} -> conn |> put_status(:internal_server_error) |> json(%{error: "chat_lookup_failed"})
        end
      {:error, conn} -> conn
    end
  end

  def show(conn, %{"id" => chat_id}) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} ->
        case Chats.get_authorized(ctx.user, chat_id) do
          {:ok, chat} -> json(conn, %{chat: chat})
          {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "chat_not_found"})
          {:error, :forbidden} -> conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
          {:error, _} -> conn |> put_status(:internal_server_error) |> json(%{error: "chat_lookup_failed"})
        end
      {:error, conn} -> conn
    end
  end

  def history(conn, %{"id" => chat_id} = params) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} ->
        limit = parse_limit(Map.get(params, "limit"))

        case Chats.history(ctx.user, chat_id, limit) do
          {:ok, messages} -> json(conn, %{chat_id: chat_id, messages: messages})
          {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "chat_not_found"})
          {:error, :forbidden} -> conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
          {:error, _} -> conn |> put_status(:internal_server_error) |> json(%{error: "chat_history_failed"})
        end
      {:error, conn} -> conn
    end
  end

  defp parse_limit(nil), do: 100
  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> min(n, 200)
      _ -> 100
    end
  end
  defp parse_limit(value) when is_integer(value) and value > 0, do: min(value, 200)
  defp parse_limit(_), do: 100
end
