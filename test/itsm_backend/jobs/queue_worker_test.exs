defmodule ItsmBackend.Jobs.QueueWorkerTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Jobs.QueueWorker

  # ============================================================
  # Fake AI client
  #
  # Simulates the dangerous case:
  #
  # Phoenix dispatches the job,
  # but the network result is ambiguous.
  #
  # The worker must NOT requeue the job.
  # It must wait for the lease to expire and then fail the
  # exact processing attempt closed.
  # ============================================================

  defmodule AmbiguousAIClient do
    @behaviour ItsmBackend.AIClient

    @impl true
    def ready do
      {:ok,
       %{
         "status" => "ready"
       }}
    end

    @impl true
    def execute_job(
          job_id,
          attempt,
          user_id,
          message
        ) do
      test_pid =
        Application.fetch_env!(
          :itsm_backend,
          :queue_worker_test_pid
        )

      send(
        test_pid,
        {
          :ai_dispatch,
          job_id,
          attempt,
          user_id,
          message
        }
      )

      # Simulate:
      #
      # request may have reached Python,
      # but Phoenix never received a trustworthy ACK.
      {:error,
       {
         :request_failed,
         :simulated_connection_drop
       }}
    end

    @impl true
    def run(
          _user_id,
          _message
        ) do
      {:error, :not_used}
    end

    @impl true
    def approve(_approval_id) do
      {:error, :not_used}
    end

    @impl true
    def reject(_approval_id) do
      {:error, :not_used}
    end

    @impl true
    def integrations do
      {:error, :not_used}
    end

    @impl true
    def health do
      {:ok,
       %{
         "status" => "ok"
       }}
    end
  end

  # ============================================================
  # Setup
  # ============================================================

  setup do
    original_ai_client =
      Application.get_env(
        :itsm_backend,
        :ai_client
      )

    original_test_pid =
      Application.get_env(
        :itsm_backend,
        :queue_worker_test_pid
      )

    Application.put_env(
      :itsm_backend,
      :ai_client,
      AmbiguousAIClient
    )

    Application.put_env(
      :itsm_backend,
      :queue_worker_test_pid,
      self()
    )

    on_exit(fn ->
      restore_env(
        :ai_client,
        original_ai_client
      )

      restore_env(
        :queue_worker_test_pid,
        original_test_pid
      )
    end)

    :ok
  end

  # ============================================================
  # Real worker lease-expiry recovery
  # ============================================================

  test "ambiguous dispatch fails closed after processing lease expires" do
    {:ok, created_job} =
      Jobs.create(%{
        user_id: "queue-worker-test",
        message: "Simulate an ambiguous durable AI execution."
      })

    assert created_job.status ==
             "pending"

    # A one-second lease makes the recovery path observable
    # without waiting for the normal production lease.
    start_supervised!({
      QueueWorker,
      [
        poll_interval_ms: 50,
        lease_seconds: 1
      ]
    })

    assert_receive {
                     :ai_dispatch,
                     dispatched_job_id,
                     attempt,
                     _user_id,
                     _message
                   },
                   2_000

    assert is_binary(dispatched_job_id)

    assert attempt >= 1

    # The worker intentionally leaves an ambiguous dispatch
    # in "processing" rather than blindly requeueing it.
    assert {:ok, processing_job} =
             wait_for_status(
               dispatched_job_id,
               "processing",
               500
             )

    assert processing_job.attempts ==
             attempt

    assert %DateTime{} =
             processing_job.claimed_at

    assert %DateTime{} =
             processing_job.lease_expires_at

    # After the lease expires, the QueueWorker itself must call
    # the CAS recovery path and persist a terminal failed state.
    assert {:ok, failed_job} =
             wait_for_status(
               dispatched_job_id,
               "outcome_unknown",
               3_000
             )

    assert failed_job.attempts ==
             attempt

    assert failed_job.lease_expires_at ==
             nil

    assert %DateTime{} =
             failed_job.completed_at

    assert is_binary(failed_job.error)

    assert failed_job.error =~
             "Processing lease expired"

    assert failed_job.error =~
             "automatic retry"

    # Most important safety property:
    #
    # this exact job must not be automatically dispatched again.
    refute_receive {
                     :ai_dispatch,
                     ^dispatched_job_id,
                     _new_attempt,
                     _user_id,
                     _message
                   },
                   300
  end

  # ============================================================
  # Wake-up on new work
  #
  # Each test drains the queue first, then retires the jobs it
  # created, so no other test's rows are claimed or left behind.
  # ============================================================

  test "a new job is dispatched at once, without waiting for the next poll" do
    # A poll this long would make the test time out if the worker only polled.
    start_idle_worker!()

    {:ok, created_job} =
      Jobs.create(%{
        user_id: "queue-worker-wake-test",
        message: "Dispatch this as soon as it is saved."
      })

    assert_receive {:ai_dispatch, job_id, attempt, _user_id, _message}, 2_000
    assert job_id == created_job.id
    retire!(job_id, attempt)
  end

  test "when the running job's completion arrives, the next job starts at once" do
    start_idle_worker!()

    {:ok, first} = Jobs.create(%{user_id: "queue-worker-wake-test", message: "First request."})
    assert_receive {:ai_dispatch, first_id, attempt, _user_id, _message}, 2_000
    assert first_id == first.id

    {:ok, second} = Jobs.create(%{user_id: "queue-worker-wake-test", message: "Second request."})
    # One job in flight at a time: the second one waits while the first runs.
    refute_receive {:ai_dispatch, _, _, _, _}, 200

    assert {:ok, _completed, :applied} =
             Jobs.apply_completion(first_id, attempt, "completed", %{
               "result" => %{"answer" => "done"}
             })

    assert_receive {:ai_dispatch, second_id, second_attempt, _user_id, _message}, 2_000
    assert second_id == second.id
    retire!(second_id, second_attempt)
  end

  defp start_idle_worker! do
    drain_pending!()
    start_supervised!({QueueWorker, [poll_interval_ms: 60_000, lease_seconds: 300]})
    # Let the startup tick finish so the queue is idle before the test's job exists.
    _ = :sys.get_state(QueueWorker)
    refute_received {:ai_dispatch, _, _, _, _}
  end

  # Fail closed any pending row another test left, so this test's job is the oldest.
  defp drain_pending! do
    case Jobs.claim_oldest(1) do
      {:ok, nil} ->
        :ok

      {:ok, %Job{} = leftover} ->
        {:ok, _} = Jobs.fail_processing_if_current(leftover, "Left pending by an earlier test.")
        drain_pending!()
    end
  end

  # The fake AI never completes; finish the dispatched attempt so it does not stay processing.
  defp retire!(job_id, attempt) do
    assert {:ok, _job, :applied} =
             Jobs.apply_completion(job_id, attempt, "failed", %{"error" => "Test finished."})
  end

  # ============================================================
  # Poll helper
  # ============================================================

  defp wait_for_status(
         job_id,
         expected_status,
         timeout_ms
       ) do
    deadline =
      System.monotonic_time(:millisecond) + timeout_ms

    do_wait_for_status(
      job_id,
      expected_status,
      deadline
    )
  end

  defp do_wait_for_status(
         job_id,
         expected_status,
         deadline
       ) do
    case Jobs.get(job_id) do
      {:ok,
       %Job{
         status: ^expected_status
       } = job} ->
        {:ok, job}

      {:ok, %Job{}} ->
        retry_or_timeout(
          job_id,
          expected_status,
          deadline
        )

      {:error, _reason} ->
        retry_or_timeout(
          job_id,
          expected_status,
          deadline
        )
    end
  end

  defp retry_or_timeout(
         job_id,
         expected_status,
         deadline
       ) do
    if System.monotonic_time(:millisecond) >= deadline do
      case Jobs.get(job_id) do
        {:ok, %Job{} = job} ->
          flunk(
            "expected job #{job_id} " <>
              "to reach status " <>
              "#{inspect(expected_status)}, " <>
              "but final status was " <>
              "#{inspect(job.status)}"
          )

        {:error, reason} ->
          flunk(
            "expected job #{job_id} " <>
              "to reach status " <>
              "#{inspect(expected_status)}, " <>
              "but final read failed: " <>
              inspect(reason)
          )
      end
    else
      Process.sleep(25)

      do_wait_for_status(
        job_id,
        expected_status,
        deadline
      )
    end
  end

  # ============================================================
  # Environment restoration
  # ============================================================

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
