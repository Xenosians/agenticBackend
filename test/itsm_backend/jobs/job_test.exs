defmodule ItsmBackend.Jobs.JobTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.Jobs.Job

  test "creates a pending job" do
    assert {:ok, job} =
             Job.new(%{
               user_id: "jdoe",
               message: "Is jdoe locked?"
             })

    assert byte_size(job.id) == 32

    assert job.user_id == "jdoe"

    assert job.message ==
             "Is jdoe locked?"

    assert job.status == "pending"
    assert job.attempts == 0

    assert %DateTime{} =
             job.created_at

    assert job.claimed_at == nil
    assert job.completed_at == nil
  end

  test "accepts string keys" do
    assert {:ok, job} =
             Job.new(%{
               "user_id" => "jdoe",
               "message" => "Check account"
             })

    assert job.user_id == "jdoe"
  end

  test "rejects missing user_id" do
    assert {:error,
            {
              :invalid_field,
              :user_id
            }} =
             Job.new(%{
               message: "hello"
             })
  end

  test "rejects blank message" do
    assert {:error,
            {
              :invalid_field,
              :message
            }} =
             Job.new(%{
               user_id: "jdoe",
               message: "   "
             })
  end

  test "claim moves pending job to processing" do
    {:ok, job} =
      Job.new(%{
        user_id: "jdoe",
        message: "Is jdoe locked?"
      })

    assert {:ok, claimed} =
             Job.claim(
               job,
               120
             )

    assert claimed.status ==
             "processing"

    assert claimed.attempts == 1

    assert %DateTime{} =
             claimed.claimed_at

    assert %DateTime{} =
             claimed.lease_expires_at

    assert DateTime.compare(
             claimed.lease_expires_at,
             claimed.claimed_at
           ) == :gt
  end

  test "claim rejects non-pending jobs" do
    {:ok, job} =
      Job.new(%{
        user_id: "jdoe",
        message: "hello"
      })

    {:ok, claimed} =
      Job.claim(job)

    assert {:error,
            {
              :job_not_pending,
              "processing"
            }} =
             Job.claim(claimed)
  end

  test "processing job can require approval" do
    {:ok, job} =
      Job.new(%{
        user_id: "jdoe",
        message: "Unlock jdoe"
      })

    {:ok, processing} =
      Job.claim(job)

    assert {:ok, waiting} =
             Job.transition(
               processing,
               "waiting_approval"
             )

    assert waiting.status ==
             "waiting_approval"

    assert waiting.lease_expires_at ==
             nil
  end

  test "processing job can complete" do
    {:ok, job} =
      Job.new(%{
        user_id: "jdoe",
        message: "Is jdoe locked?"
      })

    {:ok, processing} =
      Job.claim(job)

    processing =
      Job.put_result(
        processing,
        %{
          "locked" => false
        }
      )

    assert {:ok, completed} =
             Job.transition(
               processing,
               "completed"
             )

    assert completed.status ==
             "completed"

    assert completed.result == %{
             "locked" => false
           }

    assert %DateTime{} =
             completed.completed_at

    assert Job.terminal?(completed)
  end

  test "processing can return to pending for recovery" do
    {:ok, job} =
      Job.new(%{
        user_id: "jdoe",
        message: "hello"
      })

    {:ok, processing} =
      Job.claim(job)

    assert {:ok, recovered} =
             Job.transition(
               processing,
               "pending"
             )

    assert recovered.status ==
             "pending"

    assert recovered.claimed_at ==
             nil

    assert recovered.lease_expires_at ==
             nil

    # Retry accounting is preserved.
    assert recovered.attempts == 1
  end

  test "terminal jobs cannot transition again" do
    {:ok, job} =
      Job.new(%{
        user_id: "jdoe",
        message: "hello"
      })

    {:ok, processing} =
      Job.claim(job)

    {:ok, completed} =
      Job.transition(
        processing,
        "completed"
      )

    assert {:error,
            {
              :invalid_transition,
              "completed",
              "processing"
            }} =
             Job.transition(
               completed,
               "processing"
             )
  end

  test "rejects unknown status" do
    {:ok, job} =
      Job.new(%{
        user_id: "jdoe",
        message: "hello"
      })

    assert {:error,
            {
              :invalid_status,
              "banana"
            }} =
             Job.transition(
               job,
               "banana"
             )
  end
end
