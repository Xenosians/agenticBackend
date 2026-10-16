defmodule ItsmBackendWeb.JobRejectionTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.{Jobs, RuntimeConfig}
  alias ItsmBackend.Jobs.Job
  alias ItsmBackendWeb.{ApprovalDecisionTestClient, AuthTestSupport}

  setup do
    original = Application.get_env(:itsm_backend, :ai_client)
    Application.put_env(:itsm_backend, :ai_client, ApprovalDecisionTestClient)
    on_exit(fn -> Application.put_env(:itsm_backend, :ai_client, original) end)
    %{identity: AuthTestSupport.authenticated_identity!()}
  end

  test "owner rejection persists a human decision in v2 history and v1 projection", %{
    identity: id
  } do
    job = waiting_job(id)
    response = decide(id, job, :reject) |> json_response(200)
    assert response["status"] == "denied"
    assert response["error"] == "Action rejected by the user. No tool was executed."
    assert response["result"]["answer"] == response["error"]
    assert response["result"]["approval_execution"]["execution_status"] == "rejected"
    assert response["result"]["approval_execution"]["result"] == nil
    assert response["proposed_tool"] == job.proposed_tool
    assert_receive {:ai_approval_decision, :reject, "approval-fixture"}

    {:ok, stored} = Jobs.get(job.id)
    assert stored.status == "denied"
    assert stored.result == response["result"]
    assert stored.completed_at != nil

    notification_id =
      :crypto.hash(:sha256, "job:#{job.id}:#{job.attempts}:denied")
      |> Base.encode16(case: :lower)

    assert {:ok, notification} = ItsmBackend.Mail.OutboxStore.get(notification_id)
    assert notification["text_body"] =~ "You rejected the proposed action."

    legacy = auth_conn(id) |> get("/api/v1/jobs/#{job.id}") |> json_response(200)
    assert legacy["status"] == "failed"
    assert legacy["error"] == response["error"]

    history =
      auth_conn(id)
      |> get("/api/v2/chats/#{id.chat["chat_id"]}/history")
      |> json_response(200)

    assert Enum.any?(history["messages"], fn turn ->
             turn["job_id"] == job.id and turn["role"] == "assistant" and
               turn["status"] == "denied" and turn["content"] == response["error"]
           end)

    for action <- [:approve, :reject] do
      assert decide(id, job, action) |> json_response(409) == %{
               "error" => "job_not_waiting_approval",
               "status" => "denied"
             }
    end

    refute_received {:ai_approval_decision, _, _}
    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged == stored
  end

  test "rejection requires authentication, ownership and cookie CSRF before calling AI", %{
    identity: id
  } do
    job = waiting_job(id)
    path = "/api/v2/jobs/#{job.id}/reject"
    assert build_conn() |> post(path, %{}) |> json_response(401)

    other = AuthTestSupport.authenticated_identity!()
    assert auth_conn(other) |> post(path, %{}) |> json_response(403) == %{"error" => "forbidden"}

    cookie_conn = fn ->
      build_conn() |> put_req_cookie(RuntimeConfig.auth!().cookie_name, id.auth.raw_token)
    end

    assert cookie_conn.() |> post(path, %{}) |> json_response(403) == %{"error" => "csrf_failed"}

    assert cookie_conn.()
           |> put_req_header("x-csrf-token", "wrong")
           |> post(path, %{})
           |> json_response(403)

    refute_received {:ai_approval_decision, _, _}

    assert cookie_conn.()
           |> put_req_header("x-csrf-token", id.auth.csrf_token)
           |> post(path, %{})
           |> json_response(200)

    assert_receive {:ai_approval_decision, :reject, "approval-fixture"}
  end

  test "missing persisted approval or non-waiting job never reaches AI", %{identity: id} do
    waiting = waiting_job(id)

    {:ok, missing} =
      Jobs.update(%{waiting | proposed_tool: %{"tool" => "workspace_mkdir", "arguments" => %{}}})

    assert decide(id, missing, :reject) |> json_response(409) == %{
             "error" => "approval_id_missing"
           }

    {:ok, pending} =
      Jobs.create(%{
        user_id: id.user["user_id"],
        conversation_id: id.chat["chat_id"],
        message: "Pending"
      })

    assert decide(id, pending, :reject) |> json_response(409)
    refute_received {:ai_approval_decision, _, _}
  end

  test "v1 rejection shares authority and projects to failed", %{identity: id} do
    job = waiting_job(id)
    response = auth_conn(id) |> post("/api/v1/jobs/#{job.id}/reject", %{}) |> json_response(200)
    assert response["status"] == "failed"
    assert response["result"]["approval_execution"]["approval_status"] == "rejected"
    assert {:ok, %{status: "denied"}} = Jobs.get(job.id)
  end

  test "the browser cannot replace the persisted approval identity or arguments", %{identity: id} do
    job = waiting_job(id)

    forged_response =
      auth_conn(id)
      |> post("/api/v2/jobs/#{job.id}/reject", %{
        "approval_id" => "another-approval",
        "arguments" => %{"path" => "other-directory"}
      })
      |> json_response(409)

    assert forged_response == %{"error" => "approval_binding_changed"}
    refute_receive {:ai_approval_decision, _, _}

    response =
      auth_conn(id)
      |> post("/api/v2/jobs/#{job.id}/reject", %{
        "approval_id" => "approval-fixture",
        "arguments" => %{"path" => "other-directory"}
      })
      |> json_response(200)

    assert response["status"] == "denied"
    assert_receive {:ai_approval_decision, :reject, "approval-fixture"}
    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.proposed_tool == job.proposed_tool
    assert unchanged.status == "denied"
  end

  test "rejection reports an execution race's actual authority instead of claiming cancellation",
       %{identity: id} do
    for {execution, authority, status} <- [
          {"succeeded", "approved", "completed"},
          {"failed", "failed", "failed"},
          {"unresolved", "executing", "outcome_unknown"}
        ] do
      job = waiting_job(id)
      Process.put(:approval_decision_result, {:ok, outcome(execution, authority)})
      response = decide(id, job, :reject) |> json_response(200)
      assert response["status"] == status
      assert response["result"]["approval_execution"]["execution_status"] == execution
      refute response["error"] == "Action rejected by the user. No tool was executed."
      assert_receive {:ai_approval_decision, :reject, "approval-fixture"}
    end
  end

  test "an approval replay observing an AI rejection cannot execute or become completed", %{
    identity: id
  } do
    job = waiting_job(id)
    {:ok, rejected} = ItsmBackend.AIClient.Mock.reject("approval-fixture")
    Process.put(:approval_decision_result, {:ok, %{rejected | "replayed" => true}})
    response = decide(id, job, :approve) |> json_response(200)
    assert response["status"] == "denied"
    assert response["result"]["approval_execution"]["replayed"] == true
  end

  test "unclear rejection delivery and mismatched identity never pretend the action was rejected",
       %{identity: id} do
    {:ok, rejected} = ItsmBackend.AIClient.Mock.reject("different-approval")

    for result <- [{:error, {:request_failed, :timeout}}, {:ok, rejected}] do
      job = waiting_job(id)
      Process.put(:approval_decision_result, result)
      response = decide(id, job, :reject) |> json_response(200)
      assert response["status"] == "outcome_unknown"
      assert response["result"]["approval_reconciliation"]["automatic_retry"] == false
      assert response["error"] =~ "unresolved"
      refute Map.has_key?(response["result"], "approval_execution")
      assert_receive {:ai_approval_decision, :reject, "approval-fixture"}
      assert decide(id, job, :approve) |> json_response(409)
      refute_received {:ai_approval_decision, _, _}
    end
  end

  test "a late ambiguous decision cannot overwrite a concurrently persisted terminal outcome", %{
    identity: id
  } do
    job = waiting_job(id)

    Process.put(:approval_decision_result, fn _ ->
      {:ok, completed} =
        Job.transition(
          Job.put_result(job, %{"answer" => "Executed before rejection."}),
          "completed"
        )

      {:ok, _} = Jobs.complete_approval(completed)
      {:error, {:request_failed, :timeout}}
    end)

    response = decide(id, job, :reject) |> json_response(200)
    assert response["status"] == "completed"
    assert response["result"] == %{"answer" => "Executed before rejection."}
    assert response["error"] == nil
  end

  test "approval persistence compares the full proposal and attempt", %{identity: id} do
    waiting = waiting_job(id)
    {:ok, rejected} = Job.transition(waiting, "denied")

    substitute = %{
      waiting
      | proposed_tool: Map.put(waiting.proposed_tool, "arguments", %{"path" => "other"})
    }

    {:ok, _} = Jobs.update(substitute)
    assert {:error, :approval_binding_changed} = Jobs.complete_approval(rejected)
    {:ok, _} = Jobs.update(%{waiting | attempts: waiting.attempts + 1})
    assert {:error, :approval_binding_changed} = Jobs.complete_approval(rejected)
    assert {:ok, %{status: "waiting_approval"}} = Jobs.get(waiting.id)
  end

  defp waiting_job(id) do
    {:ok, job} =
      Jobs.create(%{
        user_id: id.user["user_id"],
        conversation_id: id.chat["chat_id"],
        message: "Create fixture directory"
      })

    {:ok, processing} = Job.claim(job, 60)
    {:ok, waiting} = Job.transition(processing, "waiting_approval")

    waiting
    |> Job.put_ai_metadata(
      selected_agent: "developer-specialist",
      proposed_tool: %{
        "tool" => "workspace_mkdir",
        "arguments" => %{"path" => "fixture-directory"},
        "approval_id" => "approval-fixture"
      }
    )
    |> Job.put_result(%{"answer" => "Approval required."})
    |> Jobs.update()
    |> then(fn {:ok, stored} -> stored end)
  end

  defp auth_conn(id), do: build_conn() |> AuthTestSupport.bearer_conn(id.auth.raw_token)
  defp decide(id, job, action), do: auth_conn(id) |> post("/api/v2/jobs/#{job.id}/#{action}", %{})

  defp outcome(execution, authority) do
    %{
      "approval_id" => "approval-fixture",
      "protocol_status" => "processed",
      "execution_status" => execution,
      "approval_status" => authority,
      "replayed" => true,
      "result" =>
        if(execution == "succeeded", do: %{"ok" => true, "status" => "success"}, else: nil),
      "error" => if(execution == "succeeded", do: nil, else: "Existing execution outcome.")
    }
  end
end
