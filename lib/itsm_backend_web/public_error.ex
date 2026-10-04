defmodule ItsmBackendWeb.PublicError do
  @moduledoc """
  Stable public error renderer.

  Internal exception/provider details belong in server logs, not browser JSON.
  The top-level `error` string is intentionally preserved for compatibility
  with existing clients while `message`, `retryable`, and optional
  `request_id` provide a bounded public contract.
  """

  import Plug.Conn,
    only: [
      get_req_header: 2,
      get_resp_header: 2,
      put_status: 2
    ]

  @spec render(
          Plug.Conn.t(),
          Plug.Conn.status(),
          String.t(),
          String.t(),
          keyword()
        ) :: Plug.Conn.t()
  def render(
        conn,
        status,
        code,
        message,
        opts \\ []
      )
      when is_binary(code) and
             is_binary(message) do
    payload = %{
      error: code,
      message: message,
      retryable:
        Keyword.get(
          opts,
          :retryable,
          false
        )
    }

    payload =
      case request_id(conn) do
        nil ->
          payload

        request_id ->
          Map.put(
            payload,
            :request_id,
            request_id
          )
      end

    conn
    |> put_status(status)
    |> Phoenix.Controller.json(payload)
  end

  defp request_id(conn) do
    response_id =
      conn
      |> get_resp_header("x-request-id")
      |> List.first()

    request_id =
      conn
      |> get_req_header("x-request-id")
      |> List.first()

    normalize_id(response_id) ||
      normalize_id(request_id)
  end

  defp normalize_id(value)
       when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_id(_value),
    do: nil
end
