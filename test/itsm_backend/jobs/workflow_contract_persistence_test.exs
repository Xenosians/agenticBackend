defmodule ItsmBackend.Jobs.WorkflowContractPersistenceTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.{Jobs, Surreal}
  alias ItsmBackend.Jobs.{Job, SurrealStore, WorkflowContract}
  alias ItsmBackend.WorkflowContractFixture, as: Fixture

  defp request do
    %{
      user_id: "workflow-owner-#{System.unique_integer([:positive])}",
      conversation_id: "workflow-chat-#{System.unique_integer([:positive])}",
      message: "Create the reviewed account and Jira ticket.",
      submission_id: ItsmBackend.SubmissionTestSupport.identity(),
      workflow_contract: Fixture.contract()
    }
  end

  test "round trips the reviewed contract and digest without resetting replayed state" do
    attrs = request()
    assert {:ok, job} = Jobs.create(attrs)
    assert job.workflow_contract == attrs.workflow_contract

    assert :ok =
             WorkflowContract.validate_binding(job.workflow_contract, job.workflow_contract_hash)

    assert {:ok, processing} = Job.claim(job, 60)
    assert {:ok, _} = SurrealStore.update(processing)
    assert {:ok, replay} = Jobs.create(attrs)
    assert replay.attempts == 1
    assert replay.workflow_contract_hash == job.workflow_contract_hash
    assert {:ok, [stored]} = Jobs.list_by_conversation(job.user_id, job.conversation_id)
    assert stored.workflow_contract == attrs.workflow_contract
  end

  test "submission identity cannot be rebound to changed or omitted obligations" do
    attrs = request()
    assert {:ok, job} = Jobs.create(attrs)

    changed =
      put_in(attrs.workflow_contract, ["steps", Access.at(0), "grounded_arguments", "user_id"], [
        "another"
      ])

    assert {:error, :submission_conflict} = Jobs.create(%{attrs | workflow_contract: changed})
    assert {:error, :submission_conflict} = Jobs.create(Map.delete(attrs, :workflow_contract))
    assert {:ok, untouched} = Jobs.get(job.id)
    assert untouched.workflow_contract == attrs.workflow_contract

    assert {:ok, independent} =
             Jobs.create(%{
               attrs
               | user_id: "another-#{attrs.user_id}",
                 workflow_contract: changed
             })

    refute independent.id == job.id
  end

  test "ordinary updates cannot change either immutable workflow field" do
    assert {:ok, job} = Jobs.create(request())

    changed =
      put_in(job.workflow_contract, ["steps", Access.at(0), "grounded_arguments", "user_id"], [
        "another"
      ])

    {:ok, _, new_hash} = WorkflowContract.validate(changed)

    assert {:error, :not_found} =
             SurrealStore.update(%{
               job
               | workflow_contract: changed,
                 workflow_contract_hash: new_hash
             })

    assert {:error, :not_found} =
             SurrealStore.update(%{job | workflow_contract_hash: String.duplicate("f", 64)})

    assert {:ok, untouched} = Jobs.get(job.id)
    assert untouched.workflow_contract_hash == job.workflow_contract_hash
  end

  test "completion compare-and-set cannot overwrite the binding" do
    assert {:ok, job} = Jobs.create(request())
    assert {:ok, processing} = Job.claim(job, 60)
    assert {:ok, _} = SurrealStore.update(processing)
    assert {:ok, completed} = Job.transition(processing, "completed")

    assert {:ok, nil} =
             SurrealStore.complete_if_processing(%{
               completed
               | workflow_contract: nil,
                 workflow_contract_hash: nil
             })

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.status == "processing"
    assert {:ok, done} = SurrealStore.complete_if_processing(completed)
    assert done.workflow_contract == job.workflow_contract
  end

  test "historical records with absent workflow columns remain readable and updatable" do
    assert {:ok, job} = Jobs.create(Map.delete(request(), :workflow_contract))

    assert {:ok, _} =
             Surreal.query(
               "UPDATE type::record('job', $id) UNSET workflow_contract, workflow_contract_hash;",
               %{"id" => job.id}
             )

    assert {:ok, legacy} = Jobs.get(job.id)
    assert legacy.workflow_contract == nil
    assert legacy.workflow_contract_hash == nil
    assert {:ok, processing} = Job.claim(legacy, 60)
    assert {:ok, stored} = SurrealStore.update(processing)
    assert stored.status == "processing"
  end

  test "a corrupted persisted digest is rejected instead of trusted" do
    assert {:ok, job} = Jobs.create(request())

    assert {:ok, _} =
             Surreal.query(
               "UPDATE type::record('job', $id) SET status = 'failed', workflow_contract_hash = $hash;",
               %{"id" => job.id, "hash" => String.duplicate("f", 64)}
             )

    assert {:error, {:invalid_field, :workflow_contract}} = Jobs.get(job.id)
  end

  test "approval continuation and completion preserve the original requested workflow" do
    assert {:ok, job} = Jobs.create(request())

    proposal = %{
      "approval_id" => "workflow-fixture-approval",
      "tool" => "create_user_account",
      "arguments" => %{"user_id" => "alice"}
    }

    waiting = %{job | status: "waiting_approval", attempts: 1, proposed_tool: proposal}
    assert {:ok, stored} = SurrealStore.update(waiting)
    changed = %{stored | workflow_contract: nil, workflow_contract_hash: nil}
    assert {:error, :approval_binding_changed} = Jobs.continue_approval(stored, changed)
    assert {:ok, nil} = SurrealStore.continue_if_waiting_approval(stored, changed)

    assert {:ok, nil} =
             SurrealStore.complete_if_waiting_approval(%{changed | status: "completed"})

    assert {:ok, untouched} = Jobs.get(job.id)
    assert untouched.workflow_contract_hash == stored.workflow_contract_hash
    assert untouched.status == "waiting_approval"

    assert {:ok, completed} =
             SurrealStore.complete_if_waiting_approval(%{stored | status: "completed"})

    assert completed.workflow_contract == job.workflow_contract
  end
end
