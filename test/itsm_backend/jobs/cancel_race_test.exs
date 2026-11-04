defmodule ItsmBackend.Jobs.CancelRaceTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job

  # The owner's cancel and the AI's completion can cross. Whichever is saved
  # first wins; the other never overwrites it.

  test "a completion saved first wins over a cancel of the read job" do
    {:ok, job} = Jobs.create(%{user_id: "cancel-race", message: "Race"})
    {:ok, processing} = Job.claim(job, 60)
    {:ok, processing} = Jobs.update(processing)

    {:ok, _, :applied} =
      Jobs.apply_completion(processing.id, processing.attempts, "completed", %{
        "result" => %{"answer" => "done"}
      })

    # The cancel was decided from the stale read (still processing).
    assert {:error, {:job_already_finished, "completed"}} = Jobs.cancel(processing)
    assert {:ok, %{status: "completed", result: %{"answer" => "done"}}} = Jobs.get(job.id)
  end

  test "a claim saved first moves a pending cancel to the running attempt" do
    {:ok, job} = Jobs.create(%{user_id: "cancel-race", message: "Race"})
    {:ok, processing} = Job.claim(job, 60)
    {:ok, _} = Jobs.update(processing)

    assert {:ok, cancelled, :processing} = Jobs.cancel(job)
    assert cancelled.status == "cancelled"
    assert cancelled.attempts == processing.attempts
  end
end
