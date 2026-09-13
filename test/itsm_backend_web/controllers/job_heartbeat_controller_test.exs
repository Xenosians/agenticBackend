defmodule ItsmBackendWeb.JobHeartbeatControllerTest do
  use ItsmBackendWeb.ConnCase,
    async: false

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Jobs.SurrealStore

  @internal_token "heartbeat-controller-test-token"

  setup do
    original_token =
      Application.get_env(
        :itsm_backend,
        :internal_job_token
      )

    Application.put_env(
      :itsm_backend,
      :internal_job_token,
      @internal_token
    )

    on_exit(fn ->
      restore_env(
        :internal_job_token,
        original_token
      )
    end)

    :ok
  end

  test "renews only the current processing attempt",
       %{conn: conn} do
    {:ok, job} =
      Job.new(%{
        user_id:
          "heartbeat-test-user",
        message:
          "Simulate a long-running AI request."
      })

    {:ok, created_job} =
      SurrealStore.create(
        job
      )

    # Short initial lease.
    #
    # The heartbeat endpoint should replace this with the normal
    # configured queue lease without incrementing the attempt.
    {:ok, processing_job} =
      Job.claim(
        created_job,
        30
      )

    {:ok, stored_processing} =
      SurrealStore.update(
        processing_job
      )

    old_expiry =
      stored_processing
      .lease_expires_at

    attempt =
      stored_processing
      .attempts

    conn =
      post_heartbeat(
        conn,
        stored_processing.id,
        attempt
      )

    response =
      json_response(
        conn,
        200
      )

    assert response[
             "job_id"
           ] ==
             stored_processing.id

    assert response[
             "attempt"
           ] ==
             attempt

    assert response[
             "status"
           ] ==
             "processing"

    assert is_binary(
             response[
               "lease_expires_at"
             ]
           )

    assert {:ok,
            renewed_expiry,
            _offset} =
             DateTime.from_iso8601(
               response[
                 "lease_expires_at"
               ]
             )

    assert DateTime.compare(
             renewed_expiry,
             old_expiry
           ) ==
             :gt

    # Heartbeat must never create a new execution attempt.
    assert {:ok, renewed_job} =
             Jobs.get(
               stored_processing.id
             )

    assert renewed_job.attempts ==
             attempt

    assert renewed_job.status ==
             "processing"

    assert DateTime.compare(
             renewed_job.lease_expires_at,
             old_expiry
           ) ==
             :gt

    # An old/future attempt cannot extend this job.
    stale_conn =
      post_heartbeat(
        Phoenix.ConnTest.build_conn(),
        stored_processing.id,
        attempt + 1
      )

    assert json_response(
             stale_conn,
             409
           ) == %{
             "error" =>
               "stale_attempt",
             "current_attempt" =>
               attempt,
             "received_attempt" =>
               attempt + 1
           }

    # Keep the persistent SurrealDB test environment clean.
    assert {:ok, cleaned_job} =
             Jobs.fail_processing_if_current(
               renewed_job,
               "Heartbeat controller test cleanup."
             )

    assert cleaned_job.status ==
             "failed"
  end

  defp post_heartbeat(
         conn,
         job_id,
         attempt
       ) do
    payload = %{
      "attempt" =>
        attempt
    }

    conn
    |> Plug.Conn.put_req_header(
      "content-type",
      "application/json"
    )
    |> Plug.Conn.put_req_header(
      "x-internal-token",
      @internal_token
    )
    |> post(
      "/api/internal/v1/jobs/" <>
        job_id <>
        "/heartbeat",
      Jason.encode!(
        payload
      )
    )
  end

  defp restore_env(
         key,
         nil
       ) do
    Application.delete_env(
      :itsm_backend,
      key
    )
  end

  defp restore_env(
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
