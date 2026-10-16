defmodule ItsmBackendWeb.JobWorkflowTest do
  use ItsmBackendWeb.ConnCase, async: false
  alias ItsmBackend.{Jobs, Chats}
  alias ItsmBackend.Jobs.Job
  alias ItsmBackendWeb.{ApprovalDecisionTestClient, AuthTestSupport}

  setup do
    original = Application.get_env(:itsm_backend, :ai_client)
    Application.put_env(:itsm_backend, :ai_client, ApprovalDecisionTestClient)
    on_exit(fn -> Application.put_env(:itsm_backend, :ai_client, original) end)
    %{identity: AuthTestSupport.authenticated_identity!()}
  end

  test "account approval advances the same job to a distinct saved Jira approval", %{identity: id} do
    job = waiting_job(id)
    Process.put(:approval_decision_result, {:ok, account_response()})
    response = decide(id, job, "account-approval") |> json_response(200)
    assert response["status"] == "waiting_approval"
    assert response["proposed_tool"]["approval_id"] == "ticket-approval"
    assert response["proposed_tool"]["tool"] == "ticket_create"
    assert length(response["result"]["approval_history"]) == 1
    assert response["result"]["approval_execution"]["execution_status"] == "succeeded"
    assert {:ok, messages} = Chats.history(id.user, id.chat["chat_id"], 100, 2)

    assert Enum.any?(
             messages,
             &(&1["job_id"] == job.id and &1["status"] == "waiting_approval")
           )

    assert_receive {:ai_approval_decision, :approve, "account-approval"}

    # A delayed click or transport replay of the first card cannot approve Jira.
    assert decide(id, job, "account-approval") |> json_response(409) == %{
             "error" => "approval_binding_changed"
           }

    refute_receive {:ai_approval_decision, :approve, "ticket-approval"}
    assert {:ok, current} = Jobs.get(job.id)
    assert current.proposed_tool["approval_id"] == "ticket-approval"
  end

  test "workflow decisions require the displayed exact approval binding", %{identity: id} do
    job = waiting_job(id)

    for body <- [%{}, %{"approval_id" => "other"}] do
      conn = auth_conn(id) |> post("/api/v2/jobs/#{job.id}/approve", body)
      assert json_response(conn, 409) == %{"error" => "approval_binding_changed"}
    end

    refute_receive {:ai_approval_decision, _, _}
  end

  test "missing or substituted continuation never marks partial work completed", %{identity: id} do
    for transform <- [
          fn value -> Map.delete(value, "continuation") end,
          fn value -> put_in(value, ["continuation", "source_approval_id"], "forged") end,
          fn value ->
            put_in(value, ["continuation", "proposed_tool", "approval_id"], "account-approval")
          end,
          fn value ->
            put_in(value, ["continuation", "result", "workflow", "account", "user_id"], "other")
          end
        ] do
      job = waiting_job(id)
      Process.put(:approval_decision_result, {:ok, transform.(account_response())})
      response = decide(id, job, "account-approval") |> json_response(200)
      assert response["status"] == "outcome_unknown"
      assert response["proposed_tool"] == job.proposed_tool
    end
  end

  test "verified Jira completion preserves both approvals and terminal replay protection", %{
    identity: id
  } do
    job = waiting_job(id)
    Process.put(:approval_decision_result, {:ok, account_response()})
    decide(id, job, "account-approval") |> json_response(200)
    Process.put(:approval_decision_result, {:ok, ticket_response(true)})
    response = decide(id, job, "ticket-approval") |> json_response(200)
    assert response["status"] == "completed"
    assert response["result"]["workflow"]["state"] == "completed"
    assert length(response["result"]["approval_history"]) == 2
    assert decide(id, job, "ticket-approval") |> json_response(409)
  end

  test "unverified Jira result keeps the real result but requires reconciliation", %{identity: id} do
    job = waiting_job(id)
    Process.put(:approval_decision_result, {:ok, account_response()})
    decide(id, job, "account-approval") |> json_response(200)
    Process.put(:approval_decision_result, {:ok, ticket_response(false)})
    response = decide(id, job, "ticket-approval") |> json_response(200)
    assert response["status"] == "outcome_unknown"
    assert response["result"]["approval_execution"]["result"]["verification_ok"] == false
    assert response["error"] =~ "Do not repeat"
  end

  test "continuation persistence compares previous proposal and attempt", %{identity: id} do
    job = waiting_job(id)

    next = %{
      job
      | proposed_tool: %{
          "tool" => "ticket_create",
          "approval_id" => "ticket-approval",
          "arguments" => %{}
        }
    }

    {:ok, _} = Jobs.update(%{job | attempts: job.attempts + 1})
    assert {:error, :approval_binding_changed} = Jobs.continue_approval(job, next)
    {:ok, _} = Jobs.update(job)
    assert {:ok, _} = Jobs.continue_approval(job, next)
    assert {:error, :approval_binding_changed} = Jobs.continue_approval(job, next)
  end

  defp waiting_job(id) do
    {:ok, job} =
      Jobs.create(%{
        user_id: id.user["user_id"],
        conversation_id: id.chat["chat_id"],
        message: "Create account then Jira"
      })

    {:ok, processing} = Job.claim(job, 60)
    {:ok, waiting} = Job.transition(processing, "waiting_approval")

    {:ok, stored} =
      waiting
      |> Job.put_ai_metadata(
        selected_agent: "account-specialist",
        proposed_tool: %{
          "tool" => "account_create",
          "arguments" => %{"given_name" => "Fixture"},
          "approval_id" => "account-approval"
        }
      )
      |> Job.put_result(%{
        "answer" => "Approve account first.",
        "workflow" => %{
          "kind" => "account_ticket",
          "state" => "awaiting_account_approval",
          "source_approval_id" => "account-approval"
        }
      })
      |> Jobs.update()

    stored
  end

  defp account_response do
    account = %{
      "ok" => true,
      "status" => "executed",
      "operation" => "account_create",
      "account_created" => true,
      "verification_ok" => true,
      "credential_persisted" => true,
      "user_id" => "fixture",
      "email" => "fixture@itsm.test"
    }

    proposal = %{
      "tool" => "ticket_create",
      "arguments" => %{"project_key" => "LAB", "summary" => "fixture onboarding"},
      "approval_id" => "ticket-approval"
    }

    result = %{
      "status" => "approval_required",
      "answer" => "Approve Jira next.",
      "routes" => ["ticket-specialist"],
      "results" => [
        %{
          "agent_name" => "ticket-specialist",
          "status" => "approval_required",
          "proposed_tool" => "ticket_create",
          "proposed_arguments" => proposal["arguments"],
          "approval_id" => "ticket-approval"
        }
      ],
      "workflow" => %{
        "kind" => "account_ticket",
        "state" => "awaiting_ticket_approval",
        "source_approval_id" => "account-approval",
        "account" => Map.take(account, ["user_id", "email"])
      }
    }

    Map.put(protocol("account-approval", account), "continuation", %{
      "kind" => "account_ticket",
      "source_approval_id" => "account-approval",
      "status" => "waiting_approval",
      "proposed_tool" => proposal,
      "result" => result,
      "error" => nil
    })
  end

  defp ticket_response(verified),
    do:
      protocol("ticket-approval", %{
        "ok" => true,
        "status" => "success",
        "provider" => "jira",
        "operation" => "create_ticket",
        "verification_ok" => verified,
        "mutation_performed" => true,
        "new_value" => "fixture onboarding",
        "ticket_key" => "LAB-1"
      })

  defp protocol(id, result),
    do: %{
      "approval_id" => id,
      "protocol_status" => "processed",
      "execution_status" => "succeeded",
      "approval_status" => "approved",
      "replayed" => false,
      "result" => result,
      "error" => nil
    }

  defp auth_conn(id), do: build_conn() |> AuthTestSupport.bearer_conn(id.auth.raw_token)

  defp decide(id, job, approval),
    do: auth_conn(id) |> post("/api/v2/jobs/#{job.id}/approve", %{"approval_id" => approval})
end
