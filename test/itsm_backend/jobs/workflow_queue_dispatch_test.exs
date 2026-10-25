defmodule ItsmBackend.Jobs.WorkflowQueueDispatchTest do
  use ExUnit.Case, async: false
  @behaviour ItsmBackend.AIClient

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.{Events, Job, QueueWorker, SurrealStore}
  alias ItsmBackend.JobQueueTestSupport
  alias ItsmBackendWeb.StorageFaultProxy

  # The proxy sees statements after parameter binding, where `$status` has
  # become a bound decode expression. Match the statement's shape instead.
  @failed_disposition ~r/SET\s+status = [^,]+,\s+error = /
  @test_cleanup_error "Expired processing row cleaned during workflow queue test setup."

  setup do
    original_client = Application.fetch_env!(:itsm_backend, :ai_client)
    original_pid = Application.get_env(:itsm_backend, :workflow_queue_test_pid)
    Application.put_env(:itsm_backend, :ai_client, __MODULE__)
    Application.put_env(:itsm_backend, :workflow_queue_test_pid, self())
    JobQueueTestSupport.drain_expired_processing!(@test_cleanup_error)

    on_exit(fn ->
      Application.put_env(:itsm_backend, :ai_client, original_client)

      if original_pid,
        do: Application.put_env(:itsm_backend, :workflow_queue_test_pid, original_pid),
        else: Application.delete_env(:itsm_backend, :workflow_queue_test_pid)
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
  def execute_job(job_id, _attempt, _owner, _message), do: unexpected_dispatch(job_id, 4)
  @impl true
  def execute_job(job_id, _attempt, _owner, _message, _context),
    do: unexpected_dispatch(job_id, 5)

  defp unexpected_dispatch(job_id, arity) do
    send(
      Application.fetch_env!(:itsm_backend, :workflow_queue_test_pid),
      {:legacy_dispatch, job_id, arity}
    )

    {:error, :unexpected_legacy_dispatch}
  end

  test "a missing workflow callback immediately fails the exact job without AI dispatch" do
    job = pending_job!()
    worker = start_worker!()
    failed = await_failed!(job.id)
    assert failed.error =~ "workflow_client_unsupported"
    assert failed.attempts == 1
    assert failed.lease_expires_at == nil
    assert failed.workflow_contract == job.workflow_contract
    assert failed.workflow_contract_hash == job.workflow_contract_hash
    assert %{inflight_job_id: nil, undispatched_failure: nil} = :sys.get_state(worker)
    refute_dispatch!(job)
  end

  test "a failed disposition write retries only its same-claim persistence" do
    job = pending_job!()
    restore = StorageFaultProxy.install!(:http_500, @failed_disposition)
    worker = start_worker!()
    assert_receive {:storage_fault, :http_500}, 2_000

    assert %{inflight_job_id: nil, undispatched_failure: %Job{id: id, attempts: 1}} =
             :sys.get_state(worker)

    assert id == job.id
    assert {:ok, processing} = Jobs.get(job.id)
    assert processing.status == "processing"
    restore.()
    send(worker, :tick)
    assert %{inflight_job_id: nil, undispatched_failure: nil} = :sys.get_state(worker)
    failed = await_failed!(job.id)
    assert failed.attempts == 1
    assert failed.workflow_contract_hash == job.workflow_contract_hash
    refute_dispatch!(job)
  end

  test "a changed lease invalidates pending disposition without resetting the job" do
    job = pending_job!()
    restore = StorageFaultProxy.install!(:http_500, @failed_disposition)
    worker = start_worker!()
    assert_receive {:storage_fault, :http_500}, 2_000
    assert %{undispatched_failure: %Job{}} = :sys.get_state(worker)
    restore.()
    assert {:ok, processing} = Jobs.get(job.id)

    renewed = %{
      processing
      | lease_expires_at: DateTime.add(processing.lease_expires_at, 120, :second)
    }

    assert {:ok, _} = SurrealStore.update(renewed)
    send(worker, :tick)
    assert %{inflight_job_id: nil, undispatched_failure: nil} = :sys.get_state(worker)
    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.status == "processing"
    assert unchanged.attempts == 1
    assert unchanged.lease_expires_at == renewed.lease_expires_at
    assert unchanged.workflow_contract_hash == job.workflow_contract_hash
    refute_dispatch!(job)
  end

  defp pending_job! do
    assert {:ok, job} =
             Jobs.create(%{
               user_id: "workflow-queue-owner-#{System.unique_integer([:positive])}",
               message: "Perform the explicitly reviewed workflow.",
               workflow_contract: ItsmBackend.WorkflowContractFixture.contract()
             })

    # Choose the first queue position in this isolated test database without
    # altering any other fixture row or relying on another test's cleanup.
    assert {:ok, stored} =
             SurrealStore.update(%{job | created_at: ~U[1970-01-01 00:00:00.000000Z]})

    :ok = Phoenix.PubSub.subscribe(ItsmBackend.PubSub, Events.topic(job.id))
    stored
  end

  defp start_worker! do
    start_supervised!({QueueWorker, [poll_interval_ms: 60_000, lease_seconds: 60]})
  end

  defp refute_dispatch!(%Job{id: job_id}) do
    refute_receive {:legacy_dispatch, ^job_id, _}
  end

  defp await_failed!(job_id) do
    assert_receive {:job_persisted, ^job_id}, 2_000
    assert {:ok, job} = Jobs.get(job_id)
    if job.status == "failed", do: job, else: await_failed!(job_id)
  end
end
