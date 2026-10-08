defmodule ItsmBackend.Jobs.ApprovalOutcomeTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.Jobs.ApprovalOutcome

  test "maps succeeded execution to completed" do
    assert {:ok, outcome} =
             ApprovalOutcome.normalize(%{
               "approval_id" => "a1",
               "protocol_status" => "processed",
               "execution_status" => "succeeded",
               "approval_status" => "approved",
               "replayed" => false,
               "result" => %{"ok" => true, "status" => "success"},
               "error" => nil
             })

    assert ApprovalOutcome.target_job_status(outcome) == "completed"
    assert ApprovalOutcome.message(outcome) == nil
  end

  test "maps deterministic execution failure to failed" do
    assert {:ok, outcome} =
             ApprovalOutcome.normalize(%{
               "approval_id" => "a2",
               "protocol_status" => "processed",
               "execution_status" => "failed",
               "approval_status" => "failed",
               "replayed" => false,
               "result" => %{"ok" => false, "error" => "tests failed"},
               "error" => "tests failed"
             })

    assert ApprovalOutcome.target_job_status(outcome) == "failed"
    assert ApprovalOutcome.message(outcome) == "tests failed"
  end

  test "maps ambiguous execution to reconciliation_required" do
    assert {:ok, outcome} =
             ApprovalOutcome.normalize(%{
               "approval_id" => "a3",
               "protocol_status" => "processed",
               "execution_status" => "unresolved",
               "approval_status" => "executing",
               "replayed" => true,
               "result" => %{"ok" => false, "status" => "outcome_unknown"},
               "error" => nil
             })

    assert ApprovalOutcome.target_job_status(outcome) == "reconciliation_required"
    assert ApprovalOutcome.message(outcome) =~ "reconciliation"
  end

  test "rejects contradictory authority state" do
    assert {:error,
            {:invalid_approval_outcome,
             {:authority_state_mismatch, _, _, _}}} =
             ApprovalOutcome.normalize(%{
               "approval_id" => "a4",
               "protocol_status" => "processed",
               "execution_status" => "failed",
               "approval_status" => "executing",
               "replayed" => false,
               "result" => nil,
               "error" => "bad"
             })
  end
end
