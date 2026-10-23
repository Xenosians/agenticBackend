defmodule ItsmBackend.AIClient.ContextContractTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.AIClient.JobContract
  alias ItsmBackend.WorkflowContractFixture, as: Fixture

  test "execution request carries only an intact Phoenix-computed workflow binding" do
    binding = Fixture.binding()

    assert {:ok, payload} =
             JobContract.build_execute_request(
               "job-1",
               1,
               "owner",
               "Create reviewed operations",
               [],
               binding
             )

    assert payload["workflow_contract"] == binding["workflow_contract"]
    assert payload["workflow_contract_hash"] == binding["workflow_contract_hash"]

    assert {:error, {:invalid_ai_job_execute_request, _}} =
             JobContract.build_execute_request(
               "job-1",
               1,
               "owner",
               "Create reviewed operations",
               [],
               Map.put(binding, "workflow_contract_hash", String.duplicate("0", 64))
             )

    assert {:error, {:invalid_ai_job_execute_request, _}} =
             JobContract.build_execute_request(
               "job-1",
               1,
               "owner",
               "Create reviewed operations",
               [],
               Map.delete(binding, "workflow_contract_hash")
             )
  end

  test "build_execute_request/5 carries bounded conversation context" do
    context = [
      %{"role" => "user", "content" => "Create Alice"},
      %{"role" => "assistant", "content" => "Alice created"}
    ]

    assert {:ok, payload} =
             JobContract.build_execute_request(
               "job-1",
               1,
               "user-1",
               "What account did you just create?",
               context
             )

    assert payload["context"] == context
  end

  test "legacy build_execute_request/4 remains valid and omits context" do
    assert {:ok, payload} =
             JobContract.build_execute_request(
               "job-1",
               1,
               "user-1",
               "hello"
             )

    refute Map.has_key?(payload, "context")
  end
end
