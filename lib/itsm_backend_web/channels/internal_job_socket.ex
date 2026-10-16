defmodule ItsmBackendWeb.InternalJobSocket do
  use Phoenix.Socket

  alias ItsmBackend.RuntimeConfig

  channel "ai_jobs:*", ItsmBackendWeb.JobProgressChannel

  @impl true
  def connect(_params, socket, %{x_headers: headers}) do
    provided = for {"x-internal-token", value} <- headers, do: value
    expected = RuntimeConfig.internal_job_token!()

    case provided do
      [token] when is_binary(token) and byte_size(token) == byte_size(expected) ->
        if Plug.Crypto.secure_compare(token, expected), do: {:ok, socket}, else: :error

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
