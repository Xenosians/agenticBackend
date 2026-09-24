defmodule ItsmBackendWeb.AuthRequest do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias ItsmBackend.Auth
  alias ItsmBackend.RuntimeConfig

  def require_authenticated(conn, opts \\ []) do
    csrf? = Keyword.get(opts, :csrf, false)

    with {:ok, raw_token, transport} <- session_token(conn),
         {:ok, user, session} <- Auth.authenticate_session(raw_token),
         :ok <- validate_csrf(conn, session, transport, csrf?) do
      {:ok,
       conn
       |> assign(:current_user, user)
       |> assign(:current_session, session)
       |> assign(:auth_transport, transport),
       %{user: user, session: session, transport: transport}}
    else
      {:error, :csrf_failed} ->
        {:error,
         conn
         |> put_status(:forbidden)
         |> json(%{error: "csrf_failed"})
         |> halt()}

      _ ->
        {:error,
         conn
         |> put_status(:unauthorized)
         |> json(%{error: "authentication_required"})
         |> halt()}
    end
  end

  defp session_token(conn) do
    config = RuntimeConfig.auth!()
    conn = fetch_cookies(conn)

    case conn.req_cookies[config.cookie_name] do
      value when is_binary(value) and value != "" -> {:ok, value, :cookie}
      _ -> bearer_token(conn)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token, :bearer}
      _ -> {:error, :missing_session}
    end
  end

  defp validate_csrf(_conn, _session, _transport, false), do: :ok
  defp validate_csrf(_conn, _session, :bearer, true), do: :ok

  defp validate_csrf(conn, session, :cookie, true) do
    expected = session["csrf_token"]
    provided = get_req_header(conn, "x-csrf-token") |> List.first()

    if secure_compare(provided, expected), do: :ok, else: {:error, :csrf_failed}
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_compare(_, _), do: false
end
