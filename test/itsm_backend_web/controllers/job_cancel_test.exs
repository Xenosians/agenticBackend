defmodule ItsmBackendWeb.JobCancelTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.{Chats, Jobs, RuntimeConfig}
  alias ItsmBackend.Jobs.Job
  alias ItsmBackendWeb.AuthTestSupport

  setup do
    original = Application.get_env(:itsm_backend, :ai_client)
    Application.put_env(:itsm_backend, :ai_client, ItsmBackendWeb.CancelTestClient)
    on_exit(fn -> Application.put_env(:itsm_backend, :ai_client, original) end)
    %{identity: AuthTestSupport.authenticated_identity!()}
  end

  test "a queued request is cancelled at once and never reaches the AI", %{identity: id} do
    job = create_job!(id)

    response = cancel(id, job) |> json_response(200)

    assert response["status"] == "cancelled"
    assert response["error"] == "Cancelled before it started."
    assert response["completed_at"]
    # No longer pending, so no worker can claim it.
    assert {:ok, %{status: "cancelled", attempts: 0}} = Jobs.get(job.id)
    refute_received {:ai_cancel, _, _}
  end

  test "a running request is cancelled and the AI is told to stop that attempt", %{identity: id} do
    job = processing_job!(id)

    response = cancel(id, job) |> json_response(200)

    assert response["status"] == "cancelled"

    assert response["error"] ==
             "Cancelled while it was running. Nothing it had not finished will run."

    assert_receive {:ai_cancel, job_id, attempt}
    assert {job_id, attempt} == {job.id, job.attempts}

    # The AI's late completion of the cancelled attempt is acknowledged, not applied.
    assert {:ok, stored, :duplicate} =
             Jobs.apply_completion(job.id, job.attempts, "completed", %{
               "result" => %{"answer" => "late"}
             })

    assert stored.status == "cancelled"
    assert stored.result == nil
  end

  test "the cancelled request's chat accepts the next turn", %{identity: id} do
    job = processing_job!(id)
    cancel(id, job) |> json_response(200)

    {:ok, working} = Chats.SurrealStore.working_chat_ids(id.user["user_id"])
    refute MapSet.member?(working, id.chat["chat_id"])

    path = "/api/v1/chats/#{id.chat["chat_id"]}"
    assert auth_conn(id) |> delete(path) |> json_response(200)
  end

  test "an approval in progress is decided by approve or reject, not cancelled", %{identity: id} do
    job = waiting_job!(id)

    assert cancel(id, job) |> json_response(409) == %{
             "error" => "job_waiting_approval",
             "status" => "waiting_approval"
           }

    assert {:ok, %{status: "waiting_approval"}} = Jobs.get(job.id)
    refute_received {:ai_cancel, _, _}
  end

  test "a finished request cannot be cancelled", %{identity: id} do
    job = processing_job!(id)

    {:ok, _, :applied} =
      Jobs.apply_completion(job.id, job.attempts, "completed", %{
        "result" => %{"answer" => "done"}
      })

    assert cancel(id, job) |> json_response(409) == %{
             "error" => "job_already_finished",
             "status" => "completed"
           }

    assert {:ok, %{status: "completed"}} = Jobs.get(job.id)
  end

  test "cancel requires the owner's session and CSRF token", %{identity: id} do
    job = create_job!(id)
    path = "/api/v2/jobs/#{job.id}/cancel"

    assert build_conn() |> post(path, %{}) |> json_response(401)

    other = AuthTestSupport.authenticated_identity!()
    assert auth_conn(other) |> post(path, %{}) |> json_response(403) == %{"error" => "forbidden"}

    cookie_conn =
      build_conn() |> put_req_cookie(RuntimeConfig.auth!().cookie_name, id.auth.raw_token)

    assert cookie_conn |> post(path, %{}) |> json_response(403) == %{"error" => "csrf_failed"}

    assert {:ok, %{status: "pending"}} = Jobs.get(job.id)
    unknown = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    assert auth_conn(id) |> post("/api/v2/jobs/#{unknown}/cancel", %{}) |> json_response(404)

    # The owner's own request succeeds, and leaves nothing queued behind.
    response = auth_conn(id) |> post(path, %{}) |> json_response(200)
    assert response["status"] == "cancelled"
  end

  test "the AI not answering the stop request does not undo the cancel", %{identity: id} do
    job = processing_job!(id)
    Process.put(:ai_cancel_result, {:error, {:request_failed, :timeout}})

    response = cancel(id, job) |> json_response(200)
    assert response["status"] == "cancelled"
    assert {:ok, %{status: "cancelled"}} = Jobs.get(job.id)
  end

  test "the chat history and the v1 job read report the cancel", %{identity: id} do
    job = processing_job!(id)
    cancel(id, job) |> json_response(200)

    history =
      auth_conn(id)
      |> get("/api/v2/chats/#{id.chat["chat_id"]}/history")
      |> json_response(200)

    assert Enum.any?(history["messages"], fn turn ->
             turn["job_id"] == job.id and turn["role"] == "assistant" and
               turn["status"] == "cancelled" and
               turn["content"] ==
                 "Cancelled while it was running. Nothing it had not finished will run."
           end)

    legacy = auth_conn(id) |> get("/api/v1/jobs/#{job.id}") |> json_response(200)
    assert legacy["status"] == "failed"
  end

  defp create_job!(id) do
    {:ok, job} =
      Jobs.create(%{
        user_id: id.user["user_id"],
        conversation_id: id.chat["chat_id"],
        message: "Cancel fixture"
      })

    job
  end

  defp processing_job!(id) do
    job = create_job!(id)
    {:ok, processing} = Job.claim(job, 60)
    {:ok, stored} = Jobs.update(processing)
    stored
  end

  defp waiting_job!(id) do
    {:ok, waiting} = Job.transition(processing_job!(id), "waiting_approval")

    waiting
    |> Job.put_ai_metadata(
      selected_agent: "developer-specialist",
      proposed_tool: %{
        "tool" => "workspace_mkdir",
        "arguments" => %{"path" => "fixture-directory"},
        "approval_id" => "approval-fixture"
      }
    )
    |> Jobs.update()
    |> then(fn {:ok, stored} -> stored end)
  end

  defp auth_conn(id), do: build_conn() |> AuthTestSupport.bearer_conn(id.auth.raw_token)
  defp cancel(id, job), do: auth_conn(id) |> post("/api/v2/jobs/#{job.id}/cancel", %{})
end
