defmodule ItsmBackend.Jobs.ReconciliationRequiredTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.Jobs.Job

  test "waiting approval can terminate into reconciliation_required" do
    assert {:ok, pending} =
             Job.new(%{
               "user_id" => "user-1",
               "message" => "perform governed action"
             })

    assert {:ok, processing} = Job.claim(pending, 300)
    assert {:ok, waiting} = Job.transition(processing, "waiting_approval")

    assert {:ok, unresolved} =
             Job.transition(waiting, "reconciliation_required")

    assert unresolved.status == "reconciliation_required"
    assert unresolved.completed_at != nil
    assert Job.terminal?(unresolved)
  end
end
