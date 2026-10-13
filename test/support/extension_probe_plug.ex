defmodule ItsmBackendWeb.ExtensionProbePlug do
  @moduledoc false
  import Plug.Conn

  def init(options), do: options

  def call(conn, test_pid) do
    {:ok, body, conn} = read_body(conn)
    payload = Jason.decode!(body)
    send(test_pid, {:extension_request, payload, get_req_header(conn, "x-internal-token")})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{received_owner: payload["owner"], action: payload["action"]})
    )
  end
end
