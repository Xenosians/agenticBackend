defmodule ItsmBackend.JobsTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Jobs.SurrealStore

  test "late completion cannot overwrite a fail-closed recovered attempt" do
    {:ok, job} =
      Job.new(%{
        user_id: "developer-test",
        message: "Show me the current Git status."
      })

    {:ok, _created} =
      SurrealStore.create(job)

    {:ok, processing} =
      Job.claim(
        job,
        120
      )

    {:ok, stored_processing} =
      SurrealStore.update(
        processing
      )

    recovery_error =
      "Processing lease expired before durable AI completion. " <>
        "Execution outcome is ambiguous, so automatic retry " <>
        "was suppressed."

    assert {:ok, failed} =
             Jobs.fail_processing_if_current(
               stored_processing,
               recovery_error
             )

    assert failed.status ==
             "failed"

    assert failed.error ==
             recovery_error

    late_completion = %{
      "result" => %{
        "answer" =>
          "Git status:\n" <>
            "- Branch: main\n" <>
            "- Working tree: clean"
      },
      "selected_agent" =>
        "developer-specialist",
      "proposed_tool" => %{
        "tool" =>
          "workspace_git_status",
        "arguments" => %{}
      }
    }

    assert {:ok, acknowledged, :duplicate} =
             Jobs.apply_completion(
               job.id,
               stored_processing.attempts,
               "completed",
               late_completion
             )

    assert acknowledged.status ==
             "failed"

    assert acknowledged.error ==
             recovery_error

    assert acknowledged.result ==
             nil

    assert {:ok, fetched} =
             Jobs.get(job.id)

    assert fetched.status ==
             "failed"

    assert fetched.error ==
             recovery_error

    assert fetched.result ==
             nil

    assert fetched.selected_agent ==
             nil

    assert fetched.proposed_tool ==
             nil
  end

  test "wrong attempt is still rejected after fail-closed recovery" do
    {:ok, job} =
      Job.new(%{
        user_id: "developer-test",
        message: "Run developer operation"
      })

    {:ok, _created} =
      SurrealStore.create(job)

    {:ok, processing} =
      Job.claim(
        job,
        120
      )

    {:ok, stored_processing} =
      SurrealStore.update(
        processing
      )

    assert {:ok, failed} =
             Jobs.fail_processing_if_current(
               stored_processing,
               "lease expired"
             )

    assert failed.status ==
             "failed"

    stale_attempt =
      stored_processing.attempts + 1

    assert {:error,
            {
              :stale_attempt,
              current_attempt,
              received_attempt
            }} =
             Jobs.apply_completion(
               job.id,
               stale_attempt,
               "completed",
               %{
                 "result" => %{
                   "answer" =>
                     "late result"
                 }
               }
             )

    assert current_attempt ==
             stored_processing.attempts

    assert received_attempt ==
             stale_attempt

    assert {:ok, fetched} =
             Jobs.get(job.id)

    assert fetched.status ==
             "failed"

    assert fetched.error ==
             "lease expired"
  end
end
