defmodule ItsmBackend.Jobs.SubmissionIdempotencyTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.{Job, SurrealStore}
  alias ItsmBackendWeb.StorageFaultProxy

  defp request do
    %{
      user_id: "submission-owner-#{System.unique_integer([:positive])}",
      conversation_id: "submission-chat-#{System.unique_integer([:positive])}",
      message: "Read the test service status.",
      submission_id: ItsmBackend.SubmissionTestSupport.identity()
    }
  end

  test "concurrent copies of one submission create exactly one durable pending job" do
    attrs = request()

    outcomes =
      Task.async_stream(1..12, fn _ -> Jobs.create(attrs) end,
        max_concurrency: 12,
        timeout: 30_000
      )
      |> Enum.to_list()

    assert Enum.all?(outcomes, &match?({:ok, {:ok, %Job{}}}, &1))
    ids = Enum.map(outcomes, fn {:ok, {:ok, job}} -> job.id end)
    assert length(Enum.uniq(ids)) == 1
    # The same job identity shape the job and progress channels accept.
    assert hd(ids) =~ ~r/\A[0-9a-f]{32}\z/
    assert {:ok, [only_job]} = Jobs.list_by_conversation(attrs.user_id, attrs.conversation_id)
    assert only_job.id == hd(ids)
    assert only_job.status == "pending"
    assert only_job.attempts == 0
  end

  test "domain validation rejects malformed submission identities before storage" do
    attrs = request()

    for identity <- ["", "not-a-uuid", 123] do
      assert {:error, {:invalid_field, :submission_id}} =
               Job.new(%{attrs | submission_id: identity})
    end
  end

  test "replay after an acknowledged create response is lost returns the original job" do
    attrs = request()
    # This proxy forwards the actual CREATE to the test database and then
    # loses its response. Read-back must recover the persisted record.
    restore = StorageFaultProxy.install!(:lost_response, ~r/CREATE ONLY/)
    assert {:ok, created} = Jobs.create(attrs)
    assert_receive {:storage_fault, :lost_response}
    restore.()
    assert {:ok, recovered} = Jobs.create(attrs)
    assert recovered.id == created.id
    assert recovered.created_at == created.created_at
    assert {:ok, [_]} = Jobs.list_by_conversation(attrs.user_id, attrs.conversation_id)
  end

  test "replayed submission never resets a claimed or completed execution" do
    attrs = request()
    assert {:ok, created} = Jobs.create(attrs)
    assert {:ok, processing} = Job.claim(created, 60)
    assert {:ok, _} = SurrealStore.update(processing)
    assert {:ok, restored} = Jobs.create(attrs)
    assert restored.status == "processing"
    assert restored.attempts == 1
    assert restored.claimed_at == processing.claimed_at

    assert {:ok, completed} =
             processing
             |> Job.put_result(%{"answer" => "Observed result"})
             |> Job.transition("completed")

    assert {:ok, _} = SurrealStore.update(completed)
    assert {:ok, final} = Jobs.create(attrs)
    assert final.status == "completed"
    assert final.attempts == 1
    assert final.result == completed.result
    assert final.completed_at == completed.completed_at
  end

  test "same owner cannot rebind a submission to another message or chat" do
    attrs = request()
    assert {:ok, created} = Jobs.create(attrs)
    assert {:error, :submission_conflict} = Jobs.create(%{attrs | message: "Another action"})

    assert {:error, :submission_conflict} =
             Jobs.create(%{attrs | conversation_id: "another-chat"})

    assert {:ok, untouched} = Jobs.get(created.id)
    assert untouched.message == attrs.message
    assert untouched.conversation_id == attrs.conversation_id
  end

  test "another authenticated owner gets an independent identity for the same client UUID" do
    attrs = request()
    assert {:ok, first} = Jobs.create(attrs)
    assert {:ok, second} = Jobs.create(%{attrs | user_id: "another-#{attrs.user_id}"})
    assert first.id != second.id
    assert second.user_id != first.user_id
  end

  test "unconfirmed storage failure stays unknown and a later same-identity retry is safe" do
    attrs = request()
    restore = StorageFaultProxy.install!(:http_500, ~r/CREATE ONLY/)
    assert {:error, {:submission_outcome_unknown, _}} = Jobs.create(attrs)
    assert_receive {:storage_fault, :http_500}
    restore.()
    assert {:ok, recovered} = Jobs.create(attrs)
    assert {:ok, [only_job]} = Jobs.list_by_conversation(attrs.user_id, attrs.conversation_id)
    assert only_job.id == recovered.id
  end

  test "a chat's job list shows each job once even when storage repeats a row" do
    attrs = request()
    assert {:ok, first} = Jobs.create(attrs)

    assert {:ok, second} =
             Jobs.create(%{attrs | submission_id: ItsmBackend.SubmissionTestSupport.identity()})

    restore = StorageFaultProxy.install!(:duplicate_rows, ~r/FROM job\s+WHERE user_id/)
    assert {:ok, jobs} = Jobs.list_by_conversation(attrs.user_id, attrs.conversation_id)
    assert_receive {:storage_fault, :duplicate_rows}
    restore.()
    assert Enum.map(jobs, & &1.id) == [first.id, second.id]
  end
end
