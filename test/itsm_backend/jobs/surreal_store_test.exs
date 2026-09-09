defmodule ItsmBackend.Jobs.SurrealStoreTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Jobs.SurrealStore

  test "creates and retrieves a job" do
    {:ok, job} =
      Job.new(%{
        user_id: "jdoe",
        message: "Is jdoe locked?"
      })

    assert {:ok, created} =
             SurrealStore.create(job)

    assert created.id == job.id
    assert created.user_id == "jdoe"
    assert created.status == "pending"
    assert created.attempts == 0

    assert {:ok, fetched} =
             SurrealStore.get(job.id)

    assert fetched.id == job.id

    assert fetched.message ==
             job.message

    assert fetched.status ==
             "pending"
  end

  test "updates a job" do
    {:ok, job} =
      Job.new(%{
        user_id: "jdoe",
        message: "Check account"
      })

    assert {:ok, _created} =
             SurrealStore.create(job)

    assert {:ok, processing} =
             Job.claim(job)

    assert {:ok, updated} =
             SurrealStore.update(
               processing
             )

    assert updated.status ==
             "processing"

    assert updated.attempts == 1

    assert %DateTime{} =
             updated.claimed_at

    assert %DateTime{} =
             updated.lease_expires_at

    assert {:ok, fetched} =
             SurrealStore.get(job.id)

    assert fetched.status ==
             "processing"

    assert fetched.attempts == 1
  end

  test "returns not_found for an unknown job" do
    missing_id =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(
        case: :lower
      )

    assert {:error, :not_found} =
             SurrealStore.get(
               missing_id
             )
  end

  test "persists result and terminal state" do
    {:ok, job} =
      Job.new(%{
        user_id: "jdoe",
        message: "Is jdoe locked?"
      })

    {:ok, _created} =
      SurrealStore.create(job)

    {:ok, processing} =
      Job.claim(job)

    processing =
      Job.put_result(
        processing,
        %{
          "locked" => false
        }
      )

    {:ok, completed} =
      Job.transition(
        processing,
        "completed"
      )

    assert {:ok, stored} =
             SurrealStore.update(
               completed
             )

    assert stored.status ==
             "completed"

    assert stored.result == %{
             "locked" => false
           }

    assert %DateTime{} =
             stored.completed_at

    assert {:ok, fetched} =
             SurrealStore.get(job.id)

    assert fetched.status ==
             "completed"

    assert fetched.result == %{
             "locked" => false
           }
  end

  test "atomically fails the current processing attempt" do
    {:ok, job} =
      Job.new(%{
        user_id: "jdoe",
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

    error =
      "Processing lease expired before durable AI completion."

    assert {:ok, failed} =
             SurrealStore.fail_processing_if_current(
               stored_processing,
               error
             )

    assert failed.status ==
             "failed"

    assert failed.attempts ==
             stored_processing.attempts

    assert failed.error ==
             error

    assert failed.lease_expires_at ==
             nil

    assert %DateTime{} =
             failed.completed_at

    assert {:ok, fetched} =
             SurrealStore.get(job.id)

    assert fetched.status ==
             "failed"

    assert fetched.error ==
             error
  end

  test "processing failure compare-and-set cannot overwrite a newer state" do
    {:ok, job} =
      Job.new(%{
        user_id: "jdoe",
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

    {:ok, completed} =
      Job.transition(
        stored_processing,
        "completed"
      )

    {:ok, _stored_completed} =
      SurrealStore.update(
        completed
      )

    assert {:ok, nil} =
             SurrealStore.fail_processing_if_current(
               stored_processing,
               "lease expired"
             )

    assert {:ok, fetched} =
             SurrealStore.get(job.id)

    assert fetched.status ==
             "completed"

    assert fetched.error ==
             nil
  end
end
