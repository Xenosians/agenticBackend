defmodule ItsmBackendWeb.LearningProbePlug do
  @moduledoc false
  import Plug.Conn

  # Stands in for the AI service: records each Learning request for the test
  # process and answers with the response the test chose for that path.
  def init(options), do: options

  def call(conn, {test_pid, responses}) do
    {:ok, body, conn} = read_body(conn)

    send(
      test_pid,
      {:learning_request, conn.request_path, Jason.decode!(body),
       get_req_header(conn, "x-internal-token")}
    )

    {status, response} = Agent.get(responses, &Map.fetch!(&1, conn.request_path))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(response))
  end
end
