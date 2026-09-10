defmodule ItsmBackend.AIClient.HTTPTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.AIClient.HTTP

  # ------------------------------------------------------------
  # Test configuration + Req transport isolation
  # ------------------------------------------------------------

  setup context do
    previous_options =
      Req.default_options()

    previous_ai_service =
      Application.get_env(
        :itsm_backend,
        :ai_service
      )

    Application.put_env(
      :itsm_backend,
      :ai_service,
      base_url: "http://ai-service.test",
      run_timeout_ms: 120_000,
      execute_timeout_ms: 8_000,
      health_timeout_ms: 2_000,
      ready_timeout_ms: 3_000
    )

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

      restore_config(
        :ai_service,
        previous_ai_service
      )
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

  # ------------------------------------------------------------
  # Configuration restoration
  # ------------------------------------------------------------

  defp restore_config(
         key,
         nil
       ) do
    Application.delete_env(
      :itsm_backend,
      key
    )
  end

  defp restore_config(
         key,
         value
       ) do
    Application.put_env(
      :itsm_backend,
      key,
      value
    )
  end
end
