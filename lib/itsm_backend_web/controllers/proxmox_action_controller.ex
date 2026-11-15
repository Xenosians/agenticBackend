defmodule ItsmBackendWeb.ProxmoxActionController do
  use ItsmBackendWeb, :controller

  use ItsmBackendWeb.RequestContract

  request_contract(:index, [])

  request_contract(:create, required_body: ["node", "vmid", "action", "submission_id"])

  request_contract(:approve, [])
  request_contract(:reject, [])

  require Logger

  alias ItsmBackend.ProxmoxActions
  alias ItsmBackendWeb.AuthRequest
  alias ItsmBackendWeb.PublicError

  def index(conn, _params) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} ->
        case ProxmoxActions.list(ctx.user) do
          {:ok, actions} -> json(conn, %{actions: actions})
          {:error, reason} -> storage_failed(conn, reason)
        end

      {:error, conn} ->
        conn
    end
  end

  def create(conn, params) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} ->
        body = Map.take(params, ["node", "vmid", "action", "submission_id"])

        case ProxmoxActions.propose(ctx.user, body) do
          {:ok, action, :created} -> conn |> put_status(:created) |> json(action)
          {:ok, action, :existing} -> json(conn, action)
          {:error, reason} -> refused(conn, reason)
        end

      {:error, conn} ->
        conn
    end
  end

  def approve(conn, %{"id" => id}), do: decide(conn, id, &ProxmoxActions.approve/2)
  def reject(conn, %{"id" => id}), do: decide(conn, id, &ProxmoxActions.reject/2)

  defp decide(conn, id, decision) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} ->
        case decision.(ctx.user, id) do
          # An unconfirmed outcome is accepted, not done: the guest must be checked.
          {:ok, %{"status" => "outcome_unknown"} = action} ->
            conn |> put_status(:accepted) |> json(action)

          {:ok, action} ->
            json(conn, action)

          {:error, reason} ->
            refused(conn, reason)
        end

      {:error, conn} ->
        conn
    end
  end

  defp refused(conn, :invalid_proxmox_action),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_proxmox_action"})

  defp refused(conn, :proxmox_action_conflict),
    do: conn |> put_status(:conflict) |> json(%{error: "proxmox_action_conflict"})

  defp refused(conn, :already_decided),
    do: conn |> put_status(:conflict) |> json(%{error: "proxmox_action_already_decided"})

  defp refused(conn, :not_found),
    do: conn |> put_status(:not_found) |> json(%{error: "proxmox_action_not_found"})

  defp refused(conn, {:refused, status, code, message}),
    do: conn |> put_status(status) |> json(%{error: code, message: message})

  defp refused(conn, :proxmox_action_unavailable),
    do: conn |> put_status(:service_unavailable) |> json(%{error: "proxmox_action_unavailable"})

  defp refused(conn, {:storage_failed, reason}), do: storage_failed(conn, reason)

  defp storage_failed(conn, reason) do
    Logger.error("proxmox action storage failed: #{inspect(reason, limit: 5)}")

    PublicError.render(
      conn,
      :service_unavailable,
      "proxmox_action_storage_failed",
      "Proxmox actions could not be saved or loaded right now.",
      retryable: true
    )
  end
end
