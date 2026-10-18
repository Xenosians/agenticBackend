defmodule ItsmBackendWeb.UserNotificationController do
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  request_contract(:create,
    required_body: ["email", "message", "dedupe_key"],
    optional_body: ["subject"]
  )

  require Logger

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackend.UserNotifications

  def create(conn, _params) do
    if authorized?(conn) do
      enqueue(conn, conn.body_params)
    else
      conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
    end
  end

  defp enqueue(conn, payload) do
    case UserNotifications.enqueue(payload) do
      {:ok, %{outbox_id: outbox_id}} ->
        # Queued, not delivered: the outbox worker owns delivery and retries.
        conn |> put_status(:accepted) |> json(%{queued: true, outbox_id: outbox_id})

      {:error, {:invalid_field, field}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_request", field: field})

      {:error, :invalid_payload} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_request"})

      {:error, :recipient_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "recipient_not_found"})

      {:error, :dedupe_conflict} ->
        conn |> put_status(:conflict) |> json(%{error: "dedupe_conflict"})

      {:error, reason} ->
        # Message text and raw database errors never enter the response.
        Logger.error("user notification enqueue failed: " <> inspect(reason, limit: 20))

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "notification_enqueue_failed"})
    end
  end

  defp authorized?(conn) do
    expected = RuntimeConfig.internal_job_token!()

    case get_req_header(conn, "x-internal-token") do
      [provided] when byte_size(provided) == byte_size(expected) ->
        Plug.Crypto.secure_compare(provided, expected)

      _ ->
        false
    end
  end
end
