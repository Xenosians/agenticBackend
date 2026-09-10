defmodule ItsmBackend.Jobs.QueueWorkerRestartRecoveryTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Jobs.QueueWorker

  # ============================================================
  # Offline AI client
  #
  # Recovery of an already-expired durable processing job must
  # not depend on the AI service being available.
  # ============================================================

  defmodule OfflineAIClient do
    @behaviour ItsmBackend.AIClient

    @impl true
    def ready do
      {:error, :simulated_offline}
    end

    @impl true
    def execute_job(
          _job_id,
          _attempt,
          _user_id,
          _message
        ) do
      {:error, :should_not_dispatch}
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
    def health do
      {:error, :simulated_offline}
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

    Application.put_env(
      :itsm_backend,
      :ai_client,
      OfflineAIClient
    )

    on_exit(fn ->
      restore_env(
        :ai_client,
        original_ai_client
      )
    end)

    :ok
  end

  # ============================================================
  # Restart recovery
  #
  # Simulate:
  #
  # 1. Phoenix had already claimed a job.
  # 2. Phoenix process dies.
  # 3. Lease expires while Phoenix is gone.
  # 4. A fresh QueueWorker starts with no local inflight state.
  #
  # The durable processing row must still be discovered and
  # failed closed.
  # ============================================================

  test "fresh worker recovers an expired durable processing job" do
    {:ok, created_job} =
      Jobs.create(%{
        user_id: "restart-recovery-test",
        message: "Simulate Phoenix restart during AI execution."
      })

    assert created_job.status ==
             "pending"

    {:ok, processing_job} =
      Job.claim(
        created_job,
        1
      )

    {:ok, stored_processing} =
      Jobs.update(processing_job)

    assert stored_processing.status ==
             "processing"

    assert stored_processing.attempts ==
             1

    assert %DateTime{} =
             stored_processing.lease_expires_at

    # Phoenix is conceptually "down" here.
    #
    # No QueueWorker owns this processing job.
    Process.sleep(1_100)

    {:ok, expired_job} =
      Jobs.get(stored_processing.id)

    assert expired_job.status ==
             "processing"

    assert DateTime.compare(
             expired_job.lease_expires_at,
             DateTime.utc_now()
           ) in [:lt, :eq]

    # Simulate Phoenix coming back.
    #
    # This worker starts with:
    #
    #   inflight_job_id: nil
    #
    start_supervised!({
      QueueWorker,
      [
        poll_interval_ms: 50,
        lease_seconds: 1
      ]
    })

    assert {:ok, recovered_job} =
             wait_for_status(
               stored_processing.id,
               "failed",
               1_000
             )

    assert recovered_job.attempts ==
             1

    assert recovered_job.lease_expires_at ==
             nil

    assert %DateTime{} =
             recovered_job.completed_at

    assert recovered_job.error =~
             "Processing lease expired"

    assert recovered_job.error =~
             "automatic retry"
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
