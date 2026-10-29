defmodule ItsmBackendWeb.ExtensionProbePlug do
  @moduledoc false
  import Plug.Conn

  def init(options), do: options

  def call(conn, test_pid) do
    {:ok, body, conn} = read_body(conn)
    payload = Jason.decode!(body)
    send(test_pid, {:extension_request, payload, get_req_header(conn, "x-internal-token")})

    case payload do
      %{"action" => "dataset_transform", "payload" => %{"script" => "refuse"}} ->
        # The AI service's curated transform refusal, plus fields that must never be forwarded.
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          422,
          Jason.encode!(%{
            detail: %{
              code: "transform_failed",
              message: "Row 3: " <> String.duplicate("x", 400),
              traceback: "private worker detail"
            }
          })
        )

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{received_owner: payload["owner"], action: payload["action"]})
        )
    end
  end
end
