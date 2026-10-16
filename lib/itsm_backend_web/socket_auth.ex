defmodule ItsmBackendWeb.SocketAuth do
  @moduledoc "Short-lived, session-bound tickets for the read-only job socket."

  alias ItsmBackend.Auth
  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.Endpoint

  @salt "job-status-socket-v1"
  @ticket_ttl 120

  def issue(user, session) do
    token = Phoenix.Token.sign(Endpoint, @salt, {user["user_id"], session["session_id"]})
    %{token: token, expires_in: @ticket_ttl}
  end

  def authenticate(token) when is_binary(token) do
    with {:ok, {user_id, session_id}} <-
           Phoenix.Token.verify(Endpoint, @salt, token, max_age: @ticket_ttl),
         {:ok, user, _session} <- Auth.authenticate_session_id(user_id, session_id) do
      {:ok, user, session_id}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authenticate(_), do: {:error, :unauthorized}

  def origin_allowed?(%URI{scheme: scheme, host: host, port: port}) do
    Enum.any?(RuntimeConfig.cors_origins!(), fn origin ->
      uri = URI.parse(origin)
      uri.scheme == scheme and uri.host == host and uri.port == port
    end)
  end
end
