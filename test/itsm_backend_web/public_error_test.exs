defmodule ItsmBackendWeb.PublicErrorTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ItsmBackendWeb.PublicError

  test "renders a bounded public error without internal reason" do
    conn =
      conn(:get, "/api/v1/jobs/job-1")
      |> put_req_header("x-request-id", "request-123")
      |> PublicError.render(
        :internal_server_error,
        "job_lookup_failed",
        "The job could not be loaded.",
        retryable: true
      )

    body = Jason.decode!(conn.resp_body)

    assert body == %{
             "error" => "job_lookup_failed",
             "message" => "The job could not be loaded.",
             "request_id" => "request-123",
             "retryable" => true
           }

    refute Map.has_key?(body, "reason")
  end
end
