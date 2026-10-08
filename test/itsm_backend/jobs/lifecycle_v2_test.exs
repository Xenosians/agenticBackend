defmodule ItsmBackend.Jobs.LifecycleV2Test do
  use ExUnit.Case, async: true
  alias ItsmBackend.Jobs.{Job, PublicContract, CompletionContract}

  test "v2 terminal states cannot be claimed, approved or requeued" do
    for status <- ["denied", "outcome_unknown"] do
      {:ok, job} = Job.new(%{user_id: "v2", message: "request"})
      {:ok, processing} = Job.claim(job, 60)
      {:ok, terminal} = Job.transition(processing, status)
      assert Job.terminal?(terminal)
      assert terminal.completed_at != nil
      assert terminal.lease_expires_at == nil
      for next <- ["pending", "processing", "waiting_approval", "completed"] do
        assert {:error, _} = Job.transition(terminal, next)
      end
      assert {:error, _} = Job.claim(terminal, 60)
      assert {:ok, v2} = PublicContract.build_job_response(terminal, 2)
      assert v2["contract_version"] == 2
      assert v2["status"] == status
      assert {:ok, v1} = PublicContract.build_job_response(terminal)
      assert v1["status"] == if(status == "denied", do: "failed", else: "reconciliation_required")
      refute Map.has_key?(v1, "contract_version")
    end
  end

  test "old persisted reconciliation rows have a v2 projection" do
    {:ok, job} = Job.new(%{user_id: "v2", message: "request"})
    assert {:ok, response} = PublicContract.build_job_response(%{job | status: "reconciliation_required"}, 2)
    assert response["status"] == "outcome_unknown"
  end

  test "new callback states require v2 and explicit error, never success data" do
    for status <- ["denied", "outcome_unknown"] do
      payload = %{"contract_version" => 2, "attempt" => 1, "status" => status,
                  "selected_agent" => nil, "proposed_tool" => nil, "error" => "Decision detail"}
      assert {:ok, ^payload} = CompletionContract.validate(payload)
      assert {:error, _} = CompletionContract.validate(Map.delete(payload, "contract_version"))
      assert {:error, _} = CompletionContract.validate(Map.put(payload, "contract_version", 3))
      assert {:error, _} = CompletionContract.validate(Map.delete(payload, "error"))
      assert {:error, _} = CompletionContract.validate(Map.put(payload, "result", %{}))
      assert {:ok, ack} = CompletionContract.build_ack("job", status, :applied, 2)
      assert ack["contract_version"] == 2
      assert ack["status"] == status
      assert {:ok, legacy_ack} = CompletionContract.build_ack("job", status, :duplicate)
      assert legacy_ack["status"] in ["failed", "reconciliation_required"]
    end
  end
end
