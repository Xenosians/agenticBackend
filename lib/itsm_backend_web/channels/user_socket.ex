defmodule ItsmBackendWeb.UserSocket do
  use Phoenix.Socket

  alias ItsmBackendWeb.SocketAuth

  channel "job:*", ItsmBackendWeb.JobChannel

  @impl true
  def connect(_params, socket, %{auth_token: token}) do
    case SocketAuth.authenticate(token) do
      {:ok, user, session_id} ->
        {:ok, assign(socket, user_id: user["user_id"], session_id: session_id)}

      {:error, _} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "job_session:" <> socket.assigns.session_id
end
