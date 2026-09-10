defmodule ItsmBackend.AIClient.HTTPTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.AIClient.HTTP

  # ------------------------------------------------------------
  # Req transport isolation
  #
  # AIClient.HTTP currently calls Req directly.
  # Req.Test lets us exercise that real path without opening
  # a socket or starting FastAPI.
  # ------------------------------------------------------------

  setup context do
    previous_options =
      Req.default_options()

    Req.Test.set_req_test_from_context(context)

    Req.Test.verify_on_exit!(context)

    Req.default_options(
      Keyword.put(
        previous_options,
        :plug,
        {Req.Test, __MODULE__}
      )
    )

    on_exit(fn ->
      Req.default_options(previous_options)
    end)

    :ok
  end

  # ------------------------------------------------------------
  # Valid request + valid acknowledgement
  # ------------------------------------------------------------

  test "execute_job sends the canonical payload and accepts a correlated acknowledgement" do
    Req.Test.expect(
      __MODULE__,
      fn conn ->
        assert conn.method ==
                 "POST"

        assert conn.request_path ==
                 "/v1/jobs/execute"

        assert conn.body_params == %{
                 "job_id" => "job-123",
                 "attempt" => 1,
                 "user_id" => "jdoe",
                 "message" => "Check account."
               }

        json_response(
          conn,
          202,
          %{
            job_id: "job-123",
            attempt: 1,
            status: "accepted",
            duplicate: false
          }
        )
      end
    )

    assert {:ok,
            %{
              "job_id" => "job-123",
              "attempt" => 1,
              "status" => "accepted",
              "duplicate" => false
            }} =
             HTTP.execute_job(
               "job-123",
               1,
               "jdoe",
               "Check account."
             )
  end

  # ------------------------------------------------------------
  # Invalid outbound request
  #
  # There is intentionally no Req.Test stub here.
  #
  # If HTTP.execute_job/4 attempts network transport despite the
  # invalid contract, Req.Test will fail the test because no stub
  # exists.
  # ------------------------------------------------------------

  test "execute_job rejects an invalid request before transport" do
    assert {:error,
            {
              :invalid_ai_job_execute_request,
              errors
            }} =
             HTTP.execute_job(
               "job-123",
               0,
               "jdoe",
               "Check account."
             )

    assert is_list(errors)
    assert errors != []
  end

  # ------------------------------------------------------------
  # Malformed acknowledgement
  # ------------------------------------------------------------

  test "execute_job rejects an acknowledgement that violates the canonical schema" do
    Req.Test.expect(
      __MODULE__,
      fn conn ->
        json_response(
          conn,
          202,
          %{
            job_id: "job-123",
            attempt: 1,
            status: "accepted"
          }
        )
      end
    )

    assert {:error,
            {
              :invalid_ai_job_ack,
              :contract_violation,
              errors
            }} =
             HTTP.execute_job(
               "job-123",
               1,
               "jdoe",
               "Check account."
             )

    assert is_list(errors)
    assert errors != []
  end

  # ------------------------------------------------------------
  # Semantically stale / wrong acknowledgement
  # ------------------------------------------------------------

  test "execute_job rejects an acknowledgement for another attempt" do
    Req.Test.expect(
      __MODULE__,
      fn conn ->
        json_response(
          conn,
          202,
          %{
            job_id: "job-123",
            attempt: 2,
            status: "accepted",
            duplicate: false
          }
        )
      end
    )

    assert {:error,
            {
              :invalid_ai_job_ack,
              :attempt_mismatch,
              1,
              2
            }} =
             HTTP.execute_job(
               "job-123",
               1,
               "jdoe",
               "Check account."
             )
  end

  # ------------------------------------------------------------
  # Response helper
  # ------------------------------------------------------------

  defp json_response(
         conn,
         status,
         body
       ) do
    encoded =
      Jason.encode!(body)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      status,
      encoded
    )
  end
end
