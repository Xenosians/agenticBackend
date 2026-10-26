defmodule ItsmBackendWeb.JobFeedbackTest do
  @moduledoc """
  Critiques and corrections (SRS 1.9 FR-089): the owner's feedback on a task is
  saved for review with links to the original request, chat, task, proposal
  and provenance. Saving feedback never changes the task or its approval.
  """
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.{Jobs, RuntimeConfig, SubmissionTestSupport}
  alias ItsmBackend.Jobs.Job
  alias ItsmBackendWeb.AuthTestSupport

  setup do
    %{owner: AuthTestSupport.authenticated_identity!()}
  end

  test "feedback is saved for review with the request, task, proposal and provenance", %{
    owner: owner
  } do
    job = waiting_job(owner)
    {:ok, before} = Jobs.get(job.id)
    submission = SubmissionTestSupport.identity()

    feedback =
      owner
      |> conn_for()
      |> post(path(job), %{
        "submission_id" => submission,
        "note" => "  It chose the wrong directory  ",
        "correction" => "Create it under reviewed/"
      })
      |> json_response(201)
      |> Map.fetch!("feedback")

    assert feedback["job_id"] == job.id
    assert feedback["chat_id"] == owner.chat["chat_id"]
    assert feedback["submission_id"] == submission
    assert feedback["kind"] == "correction"
    assert feedback["note"] == "It chose the wrong directory"
    assert feedback["correction"] == "Create it under reviewed/"
    assert feedback["review_status"] == "pending_review"

    # The subject is copied when the note is saved: a proposal awaiting a
    # decision changes once it is decided, the reviewed record must not.
    assert feedback["subject"] == %{
             "request" => "Create fixture directory",
             "status" => "waiting_approval",
             "attempt" => before.attempts,
             "selected_agent" => "developer-specialist",
             "routes" => ["developer-specialist"],
             "proposed_tool" => before.proposed_tool,
             "answer" => "Approval required.",
             "workflow_contract_hash" => nil
           }

    # Feedback is review evidence only: the task and its approval are unchanged.
    assert {:ok, after_feedback} = Jobs.get(job.id)
    assert after_feedback == before
  end

  test "a retried submission is saved once and a changed one is refused", %{owner: owner} do
    job = completed_job(owner)
    body = %{"submission_id" => SubmissionTestSupport.identity(), "note" => "It missed a server"}

    first = owner |> conn_for() |> post(path(job), body) |> json_response(201)
    assert first["feedback"]["kind"] == "critique"
    assert first["feedback"]["correction"] == nil

    replay = owner |> conn_for() |> post(path(job), body) |> json_response(200)
    assert replay == first

    changed = owner |> conn_for() |> post(path(job), %{body | "note" => "Another note"})
    assert json_response(changed, 409)["error"] == "feedback_conflict"

    assert [saved] = listed(owner, job)
    assert saved == first["feedback"]
  end

  test "only the task's owner gives feedback, and cookie sessions need CSRF", %{owner: owner} do
    job = completed_job(owner)
    body = %{"submission_id" => SubmissionTestSupport.identity(), "note" => "Wrong answer"}

    assert build_conn() |> post(path(job), body) |> json_response(401)

    other = AuthTestSupport.authenticated_identity!()

    assert other |> conn_for() |> post(path(job), body) |> json_response(403) == %{
             "error" => "forbidden"
           }

    cookie_conn =
      build_conn() |> put_req_cookie(RuntimeConfig.auth!().cookie_name, owner.auth.raw_token)

    assert cookie_conn |> post(path(job), body) |> json_response(403) == %{
             "error" => "csrf_failed"
           }

    assert listed(owner, job) == []

    owner |> conn_for() |> post(path(job), body) |> json_response(201)
    assert [_saved] = listed(owner, job)
    assert listed(other, job) == []
    assert build_conn() |> get("/api/v1/feedback") |> json_response(401)
  end

  test "a task without an answer yet and invalid feedback are refused", %{owner: owner} do
    {:ok, queued} =
      Jobs.create(%{
        user_id: owner.user["user_id"],
        conversation_id: owner.chat["chat_id"],
        message: "Still queued"
      })

    body = %{"submission_id" => SubmissionTestSupport.identity(), "note" => "Too slow"}
    refused = owner |> conn_for() |> post(path(queued), body)
    assert json_response(refused, 409)["error"] == "job_not_ready_for_feedback"

    job = completed_job(owner)

    for invalid <- [
          %{body | "note" => "   "},
          %{body | "note" => 42},
          %{body | "note" => String.duplicate("a", 2001)},
          Map.put(body, "correction", String.duplicate("b", 2001)),
          %{body | "submission_id" => "not-a-submission-identity"},
          Map.delete(body, "submission_id"),
          Map.delete(body, "note")
        ] do
      response = owner |> conn_for() |> post(path(job), invalid)
      assert json_response(response, 422)["error"] == "invalid_feedback"
    end

    missing =
      owner |> conn_for() |> post("/api/v1/jobs/#{String.duplicate("0", 32)}/feedback", body)

    assert json_response(missing, 404) == %{"error" => "job_not_found"}

    assert listed(owner, queued) == []
    assert listed(owner, job) == []
  end

  defp waiting_job(identity) do
    {:ok, job} = new_job(identity, "Create fixture directory")
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
    |> Job.put_result(%{"answer" => "Approval required.", "routes" => ["developer-specialist"]})
    |> stored!()
  end

  defp completed_job(identity) do
    {:ok, job} = new_job(identity, "List the open VPN tickets")
    {:ok, processing} = Job.claim(job, 60)
    {:ok, completed} = Job.transition(processing, "completed")

    completed
    |> Job.put_ai_metadata(selected_agent: "jira-specialist")
    |> Job.put_result(%{"answer" => "No open VPN tickets.", "routes" => ["jira-specialist"]})
    |> stored!()
  end

  defp new_job(identity, message) do
    Jobs.create(%{
      user_id: identity.user["user_id"],
      conversation_id: identity.chat["chat_id"],
      message: message
    })
  end

  defp stored!(job) do
    {:ok, stored} = Jobs.update(job)
    stored
  end

  defp listed(identity, job) do
    identity
    |> conn_for()
    |> get("/api/v1/feedback")
    |> json_response(200)
    |> Map.fetch!("feedback")
    |> Enum.filter(&(&1["job_id"] == job.id))
  end

  defp path(job), do: "/api/v1/jobs/#{job.id}/feedback"

  defp conn_for(identity),
    do: build_conn() |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
end
