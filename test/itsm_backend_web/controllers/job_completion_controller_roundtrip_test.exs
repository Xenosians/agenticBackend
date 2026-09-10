defmodule ItsmBackendWeb.JobCompletionControllerRoundtripTest do
  use ItsmBackendWeb.ConnCase,
    async: false

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job

  @internal_token "completion-roundtrip-test-token"

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

  test "valid completion is durably applied and duplicate replay is acknowledged",
       %{conn: conn} do
    # ----------------------------------------------------------
    # Create durable pending job
    # ----------------------------------------------------------

    assert {:ok, created_job} =
             Jobs.create(%{
               user_id: "completion-roundtrip-user",
               message: "Complete this durable job."
             })

    assert created_job.status ==
             "pending"

    # ----------------------------------------------------------
    # Put this exact job into processing
    #
    # We claim the job domain object directly instead of using
    # claim_oldest/1 so this test cannot accidentally consume
    # another pending row from the shared test datastore.
    # ----------------------------------------------------------

    assert {:ok, processing_job} =
             Job.claim(
               created_job,
               60
             )

    assert {:ok, stored_processing_job} =
             Jobs.update(processing_job)

    assert stored_processing_job.status ==
             "processing"

    assert stored_processing_job.attempts ==
             1

    # ----------------------------------------------------------
    # AI completion callback
    # ----------------------------------------------------------

    payload = %{
      "attempt" => stored_processing_job.attempts,
      "status" => "completed",
      "selected_agent" => "account",
      "proposed_tool" => nil,
      "result" => %{
        "answer" => "Account is enabled."
      }
    }

    conn =
      post_completion(
        conn,
        stored_processing_job.id,
        payload
      )

    # ----------------------------------------------------------
    # Canonical Phoenix completion ACK
    # ----------------------------------------------------------

    assert json_response(
             conn,
             200
           ) == %{
             "job_id" => stored_processing_job.id,
             "status" => "completed",
             "acknowledgement" => "applied"
           }

    # ----------------------------------------------------------
    # Durable state was actually persisted
    # ----------------------------------------------------------

    assert {:ok, completed_job} =
             Jobs.get(stored_processing_job.id)

    assert completed_job.status ==
             "completed"

    assert completed_job.attempts ==
             stored_processing_job.attempts

    assert completed_job.selected_agent ==
             "account"

    assert completed_job.proposed_tool ==
             nil

    assert completed_job.result == %{
             "answer" => "Account is enabled."
           }

    assert completed_job.error ==
             nil

    assert completed_job.lease_expires_at ==
             nil

    assert %DateTime{} =
             completed_job.completed_at

    # ----------------------------------------------------------
    # Exact callback replay is idempotent
    # ----------------------------------------------------------

    replay_conn =
      build_conn()
      |> post_completion(
        stored_processing_job.id,
        payload
      )

    assert json_response(
             replay_conn,
             200
           ) == %{
             "job_id" => stored_processing_job.id,
             "status" => "completed",
             "acknowledgement" => "duplicate"
           }

    # ----------------------------------------------------------
    # Duplicate replay does not alter durable result
    # ----------------------------------------------------------

    assert {:ok, replayed_job} =
             Jobs.get(stored_processing_job.id)

    assert replayed_job.status ==
             "completed"

    assert replayed_job.attempts ==
             completed_job.attempts

    assert replayed_job.result ==
             completed_job.result

    assert replayed_job.completed_at ==
             completed_job.completed_at
  end

  # ------------------------------------------------------------
  # HTTP helper
  # ------------------------------------------------------------

  defp post_completion(
         conn,
         job_id,
         payload
       ) do
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
      ~p"/api/internal/v1/jobs/#{job_id}/completion",
      Jason.encode!(payload)
    )
  end

  # ------------------------------------------------------------
  # Environment restoration
  # ------------------------------------------------------------

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
