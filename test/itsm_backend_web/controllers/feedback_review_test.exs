defmodule ItsmBackendWeb.FeedbackReviewTest do
  @moduledoc """
  The reviewer queue for critiques and corrections (SRS 1.9 FR-089). A
  reviewer (an administrator) reads pending feedback with its saved subject
  and records one decision per record. A decision is review evidence only: it
  never changes the task, its approval, tool permissions, policy or weights.
  """
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.{Jobs, RuntimeConfig, SubmissionTestSupport}
  alias ItsmBackend.Jobs.Job
  alias ItsmBackendWeb.AuthTestSupport

  setup do
    original = Application.fetch_env!(:itsm_backend, :auth)
    on_exit(fn -> Application.put_env(:itsm_backend, :auth, original) end)

    owner = AuthTestSupport.authenticated_identity!()
    reviewer = admin_identity!(original)
    %{owner: owner, reviewer: reviewer}
  end

  test "a reviewer sees pending feedback with its subject and decides it once", %{
    owner: owner,
    reviewer: reviewer
  } do
    job = completed_job(owner)
    {:ok, before} = Jobs.get(job.id)
    feedback = give_feedback(owner, job, "It missed the VPN tickets", "List SUP-14 too")

    queue = reviewer |> conn_for() |> get("/api/v1/feedback/review") |> json_response(200)
    pending = Enum.find(queue["feedback"], &(&1["feedback_id"] == feedback["feedback_id"]))
    assert pending["review_status"] == "pending_review"
    assert pending["note"] == "It missed the VPN tickets"
    assert pending["correction"] == "List SUP-14 too"
    assert pending["subject"]["request"] == "List the open VPN tickets"
    assert pending["subject"]["answer"] == "No open VPN tickets."
    # The queue names the task and chat, never the owner's email or password data.
    refute Map.has_key?(pending, "email")

    decision = %{
      "decision" => "accepted",
      "reason" => "Valid: the search dropped a status filter"
    }

    reviewed =
      reviewer
      |> conn_for()
      |> post(review_path(feedback), decision)
      |> json_response(200)
      |> Map.fetch!("feedback")

    assert reviewed["review_status"] == "accepted"
    assert reviewed["review"]["reason"] == "Valid: the search dropped a status filter"
    assert reviewed["review"]["reviewer_id"] == reviewer.user["user_id"]
    assert is_binary(reviewed["review"]["reviewed_at"])

    # Repeating the same decision returns it; a different decision is refused.
    again = reviewer |> conn_for() |> post(review_path(feedback), decision) |> json_response(200)
    assert again["feedback"] == reviewed

    changed =
      reviewer
      |> conn_for()
      |> post(review_path(feedback), %{"decision" => "dismissed", "reason" => "Changed mind"})

    assert json_response(changed, 409)["error"] == "review_conflict"

    # Decided feedback leaves the pending queue but stays in the full list.
    pending_ids =
      reviewer
      |> conn_for()
      |> get("/api/v1/feedback/review")
      |> json_response(200)
      |> Map.fetch!("feedback")
      |> Enum.map(& &1["feedback_id"])

    refute feedback["feedback_id"] in pending_ids

    all =
      reviewer
      |> conn_for()
      |> get("/api/v1/feedback/review?status=all")
      |> json_response(200)
      |> Map.fetch!("feedback")

    assert Enum.find(all, &(&1["feedback_id"] == feedback["feedback_id"]))["review_status"] ==
             "accepted"

    # The owner sees the decision on their own feedback.
    [own] =
      owner
      |> conn_for()
      |> get("/api/v1/feedback")
      |> json_response(200)
      |> Map.fetch!("feedback")
      |> Enum.filter(&(&1["feedback_id"] == feedback["feedback_id"]))

    assert own["review_status"] == "accepted"

    # Review is evidence only: the task and its approval are unchanged.
    assert {:ok, after_review} = Jobs.get(job.id)
    assert after_review == before
  end

  test "only reviewers read the queue or decide, and cookie sessions need CSRF", %{
    owner: owner,
    reviewer: reviewer
  } do
    job = completed_job(owner)
    feedback = give_feedback(owner, job, "Wrong answer", nil)
    decision = %{"decision" => "dismissed", "reason" => "Not reproducible"}

    assert build_conn() |> get("/api/v1/feedback/review") |> json_response(401)
    assert build_conn() |> post(review_path(feedback), decision) |> json_response(401)

    # The owner of the feedback is not a reviewer.
    assert owner |> conn_for() |> get("/api/v1/feedback/review") |> json_response(403) ==
             %{"error" => "forbidden"}

    assert owner |> conn_for() |> post(review_path(feedback), decision) |> json_response(403) ==
             %{"error" => "forbidden"}

    cookie_conn =
      build_conn()
      |> put_req_cookie(RuntimeConfig.auth!().cookie_name, reviewer.auth.raw_token)

    assert cookie_conn |> post(review_path(feedback), decision) |> json_response(403) ==
             %{"error" => "csrf_failed"}

    [own] =
      owner
      |> conn_for()
      |> get("/api/v1/feedback")
      |> json_response(200)
      |> Map.fetch!("feedback")
      |> Enum.filter(&(&1["feedback_id"] == feedback["feedback_id"]))

    assert own["review_status"] == "pending_review"
  end

  test "an invalid decision, reason or record is refused", %{owner: owner, reviewer: reviewer} do
    job = completed_job(owner)
    feedback = give_feedback(owner, job, "It answered too late", nil)

    for invalid <- [
          %{"decision" => "approved", "reason" => "Not a decision"},
          %{"decision" => "accepted", "reason" => "   "},
          %{"decision" => "accepted", "reason" => String.duplicate("r", 2001)},
          %{"decision" => "accepted"},
          %{"reason" => "No decision"}
        ] do
      response = reviewer |> conn_for() |> post(review_path(feedback), invalid)
      assert json_response(response, 422)["error"] == "invalid_review"
    end

    missing =
      reviewer
      |> conn_for()
      |> post("/api/v1/feedback/#{String.duplicate("0", 32)}/review", %{
        "decision" => "accepted",
        "reason" => "Exists?"
      })

    assert json_response(missing, 404) == %{"error" => "feedback_not_found"}

    invalid_filter = reviewer |> conn_for() |> get("/api/v1/feedback/review?status=everything")
    assert json_response(invalid_filter, 422)["error"] == "invalid_review_filter"
  end

  defp admin_identity!(auth_config) do
    suffix = 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    email = "reviewer-#{suffix}@example.test"
    admins = Keyword.get(auth_config, :admin_emails, [])

    Application.put_env(
      :itsm_backend,
      :auth,
      Keyword.put(auth_config, :admin_emails, [email | admins])
    )

    identity = AuthTestSupport.authenticated_identity!(email)
    "admin" = identity.user["role"]
    identity
  end

  defp give_feedback(identity, job, note, correction) do
    body =
      %{"submission_id" => SubmissionTestSupport.identity(), "note" => note}
      |> then(fn body ->
        if correction, do: Map.put(body, "correction", correction), else: body
      end)

    identity
    |> conn_for()
    |> post("/api/v1/jobs/#{job.id}/feedback", body)
    |> json_response(201)
    |> Map.fetch!("feedback")
  end

  defp completed_job(identity) do
    {:ok, job} =
      Jobs.create(%{
        user_id: identity.user["user_id"],
        conversation_id: identity.chat["chat_id"],
        message: "List the open VPN tickets"
      })

    {:ok, processing} = Job.claim(job, 60)
    {:ok, completed} = Job.transition(processing, "completed")

    {:ok, stored} =
      completed
      |> Job.put_ai_metadata(selected_agent: "jira-specialist")
      |> Job.put_result(%{"answer" => "No open VPN tickets.", "routes" => ["jira-specialist"]})
      |> Jobs.update()

    stored
  end

  defp review_path(feedback), do: "/api/v1/feedback/#{feedback["feedback_id"]}/review"

  defp conn_for(identity),
    do: build_conn() |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
end
