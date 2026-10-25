defmodule ItsmBackend.Jobs.QueueWorkerRejectionTest do
  use ExUnit.Case, async: false
  @behaviour ItsmBackend.AIClient

  import ExUnit.CaptureLog

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.{Job, QueueWorker, SurrealStore}
  alias ItsmBackend.JobQueueTestSupport
  alias ItsmBackend.WorkflowContractFixture, as: Fixture
  alias ItsmBackendWeb.StorageFaultProxy

  @private_body "sensitive-validation-context-must-not-be-persisted-or-logged"
  @failed_disposition ~r/SET\s+status = [^,]+,\s+error = /
  @test_cleanup_error "Expired processing row cleaned during rejection test setup."

  setup do
    keys = [:ai_client, :rejection_test_pid, :rejection_test_status]
    previous = Map.new(keys, &{&1, Application.fetch_env(:itsm_backend, &1)})
    Application.put_env(:itsm_backend, :ai_client, __MODULE__)
    Application.put_env(:itsm_backend, :rejection_test_pid, self())
    JobQueueTestSupport.drain_expired_processing!(@test_cleanup_error)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, saved} -> Application.put_env(:itsm_backend, key, saved)
          :error -> Application.delete_env(:itsm_backend, key)
        end
      end
    end)

    :ok
  end

  @impl true
  def ready, do: {:ok, %{"status" => "ready"}}
  @impl true
  def health, do: {:ok, %{"status" => "ok"}}
  @impl true
  def run(_, _), do: {:error, :not_used}
  @impl true
  def approve(_), do: {:error, :not_used}
  @impl true
  def reject(_), do: {:error, :not_used}
  @impl true
  def integrations, do: {:error, :not_used}
  @impl true
  def execute_job(_, _, _, _), do: {:error, :unexpected_legacy_callback}

  @impl true
  def execute_job(job_id, attempt, _owner, _message, _context, binding) do
    send(
      Application.fetch_env!(:itsm_backend, :rejection_test_pid),
      {:rejected_dispatch, job_id, attempt, binding}
    )

    {:error,
     {:ai_service_error, Application.fetch_env!(:itsm_backend, :rejection_test_status),
      %{"detail" => @private_body}}}
  end

  for status <- [400, 401, 403, 404, 405, 413, 415, 422] do
    test "HTTP #{status} terminates the exact claim without repeatedly dispatching" do
      status = unquote(status)
      Application.put_env(:itsm_backend, :rejection_test_status, status)
      job = pending_job!()
      binding = workflow_binding(job)

      log =
        capture_log(fn ->
          worker = start_worker!()
          assert_receive {:rejected_dispatch, id, 1, ^binding}, 2_000
          assert id == job.id
          assert %{inflight_job_id: nil, undispatched_failure: nil} = :sys.get_state(worker)
          assert {:ok, failed} = Jobs.get(job.id)
          assert failed.status == "failed"
          assert failed.error =~ "ai_request_rejected"
          assert failed.error =~ "HTTP #{status}"
          refute failed.error =~ @private_body
          assert failed.attempts == 1
          assert failed.lease_expires_at == nil
          assert %DateTime{} = failed.completed_at
          assert workflow_binding(failed) == binding

          send(worker, :tick)
          _ = :sys.get_state(worker)
          refute_receive {:rejected_dispatch, ^id, _, _}
          assert {:ok, unchanged} = Jobs.get(job.id)
          assert unchanged == failed
        end)

      refute log =~ @private_body
    end
  end

  test "a failed terminal write retries only the original claim's disposition" do
    Application.put_env(:itsm_backend, :rejection_test_status, 422)
    job = pending_job!()
    binding = workflow_binding(job)
    restore = StorageFaultProxy.install!(:http_500, @failed_disposition)
    worker = start_worker!()
    assert_receive {:rejected_dispatch, id, 1, ^binding}, 2_000
    assert id == job.id
    assert_receive {:storage_fault, :http_500}, 2_000

    assert %{inflight_job_id: nil, undispatched_failure: %Job{} = claim} =
             :sys.get_state(worker)

    assert claim.id == job.id
    assert claim.attempts == 1
    assert claim.error =~ "ai_request_rejected"
    assert {:ok, processing} = Jobs.get(job.id)
    assert processing.status == "processing"
    assert processing.lease_expires_at == claim.lease_expires_at
    restore.()
    send(worker, :tick)
    assert %{inflight_job_id: nil, undispatched_failure: nil} = :sys.get_state(worker)
    refute_receive {:rejected_dispatch, ^id, _, _}
    assert {:ok, failed} = Jobs.get(job.id)
    assert failed.status == "failed"
    assert failed.attempts == 1
    assert workflow_binding(failed) == binding
    assert failed.error == claim.error
  end

  for status <- [408, 409] do
    test "HTTP #{status} remains ambiguous and is never automatically redispatched" do
      log =
        capture_log(fn ->
          Application.put_env(:itsm_backend, :rejection_test_status, unquote(status))
          job = pending_job!()
          binding = workflow_binding(job)
          worker = start_worker!()
          assert_receive {:rejected_dispatch, id, 1, ^binding}, 2_000
          assert id == job.id
          assert %{inflight_job_id: ^id, undispatched_failure: nil} = :sys.get_state(worker)
          assert {:ok, processing} = Jobs.get(id)
          assert processing.status == "processing"
          assert processing.error == nil
          assert workflow_binding(processing) == binding
          send(worker, :tick)
          assert %{inflight_job_id: ^id} = :sys.get_state(worker)
          refute_receive {:rejected_dispatch, ^id, _, _}
          assert {:ok, unchanged} = Jobs.get(id)
          assert unchanged == processing

          # Advance only this fixture's lease, without a wall-clock sleep.
          assert {:ok, _} =
                   SurrealStore.update(%{processing | lease_expires_at: ~U[2000-01-01 00:00:00Z]})

          send(worker, :tick)
          assert %{inflight_job_id: nil} = :sys.get_state(worker)
          refute_receive {:rejected_dispatch, ^id, _, _}
          assert {:ok, unresolved} = Jobs.get(id)
          assert unresolved.status == "outcome_unknown"
          assert unresolved.attempts == 1
          assert workflow_binding(unresolved) == binding
        end)

      refute log =~ @private_body
    end
  end

  test "HTTP 429 retains the known-rejection requeue path and its immutable binding" do
    Application.put_env(:itsm_backend, :rejection_test_status, 429)
    job = pending_job!()
    binding = workflow_binding(job)
    worker = start_worker!()
    assert_receive {:rejected_dispatch, id, 1, ^binding}, 2_000
    assert id == job.id
    assert %{inflight_job_id: nil, undispatched_failure: nil} = :sys.get_state(worker)
    assert {:ok, pending} = Jobs.get(id)
    assert pending.status == "pending"
    assert pending.attempts == 1
    assert pending.error == nil
    assert pending.lease_expires_at == nil
    assert workflow_binding(pending) == binding

    # Retire only this test fixture, so another test cannot claim its pending row.
    assert {:ok, retired} = Job.transition(pending, "failed")
    assert {:ok, _} = SurrealStore.update(retired)
  end

  defp pending_job! do
    assert {:ok, job} =
             Jobs.create(%{
               user_id: "rejection-owner-#{System.unique_integer([:positive])}",
               message: "Perform the explicitly reviewed operation.",
               workflow_contract: Fixture.contract()
             })

    assert {:ok, first} =
             SurrealStore.update(%{job | created_at: ~U[1970-01-01 00:00:00.000000Z]})

    first
  end

  defp start_worker! do
    start_supervised!({QueueWorker, [poll_interval_ms: 60_000, lease_seconds: 60]})
  end

  defp workflow_binding(job) do
    %{
      "workflow_contract" => job.workflow_contract,
      "workflow_contract_hash" => job.workflow_contract_hash
    }
  end
end
