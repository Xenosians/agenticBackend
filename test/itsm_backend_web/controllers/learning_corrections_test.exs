defmodule ItsmBackendWeb.LearningCorrectionsTest do
  @moduledoc """
  Accepted corrections as training data (SRS 1.9 FR-085/089). The signed-in
  owner previews, then saves, the corrections a reviewer accepted on their own
  tasks as the next version of their training dataset. Only those corrections
  cross to the AI service: never pending or dismissed feedback, critiques
  without a correct result, or another owner's feedback. Saving never starts a
  run or changes what serves requests.
  """
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.{Jobs, RuntimeConfig, SubmissionTestSupport}
  alias ItsmBackend.Jobs.Job
  alias ItsmBackendWeb.AuthTestSupport

  @corrections_path "/internal/v1/learning/corrections"
  @preview %{
    "schema" => "learning-corrections.v1",
    "status" => "ready",
    "usable" => 1,
    "withheld" => 0,
    "minimum" => 10,
    "dataset" => nil
  }
  @saved_dataset %{
    "id" => String.duplicate("a", 32),
    "name" => "Accepted corrections",
    "version" => 1,
    "lineage_id" => String.duplicate("a", 32),
    "sha256" => String.duplicate("b", 64),
    "train_count" => 9,
    "validation_count" => 2
  }

  setup do
    original_auth = Application.fetch_env!(:itsm_backend, :auth)
    original_ai = Application.get_env(:itsm_backend, :ai_service)
    original_token = Application.get_env(:itsm_backend, :internal_job_token)
    responses = start_supervised!({Agent, fn -> %{@corrections_path => {200, @preview}} end})

    server =
      start_supervised!(
        {Bandit,
         plug: {ItsmBackendWeb.LearningProbePlug, {self(), responses}},
         port: 0,
         ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    Application.put_env(
      :itsm_backend,
      :ai_service,
      Keyword.put(original_ai, :base_url, "http://127.0.0.1:#{port}")
    )

    Application.put_env(:itsm_backend, :internal_job_token, "learning-test-internal")

    on_exit(fn ->
      Application.put_env(:itsm_backend, :auth, original_auth)
      Application.put_env(:itsm_backend, :ai_service, original_ai)
      Application.put_env(:itsm_backend, :internal_job_token, original_token)
    end)

    %{
      owner: AuthTestSupport.authenticated_identity!(),
      other: AuthTestSupport.authenticated_identity!(),
      reviewer: admin_identity!(original_auth),
      responses: responses
    }
  end

  test "only the owner's accepted corrections reach the preview", %{
    owner: owner,
    other: other,
    reviewer: reviewer
  } do
    accepted = feedback(owner, "Which queue handles VPN?", "Network Operations handles VPN.")
    decide(reviewer, accepted, "accepted")
    dismissed = feedback(owner, "Which queue handles mail?", "The mail team.")
    decide(reviewer, dismissed, "dismissed")
    _pending = feedback(owner, "Which queue handles printers?", "Facilities.")
    critique = feedback(owner, "Which queue handles Wi-Fi?", nil)
    decide(reviewer, critique, "accepted")
    theirs = feedback(other, "Which queue handles SAP?", "Finance applications.")
    decide(reviewer, theirs, "accepted")

    assert owner |> conn_for() |> get("/api/v1/learning/corrections") |> json_response(200) ==
             @preview

    owner_id = owner.user["user_id"]

    assert_receive {:learning_request, @corrections_path,
                    %{"owner" => ^owner_id, "apply" => false, "corrections" => sent} = body,
                    ["learning-test-internal"]}

    assert map_size(body) == 3

    assert sent == [
             %{
               "feedback_id" => accepted["feedback_id"],
               "request" => "Which queue handles VPN?",
               "correction" => "Network Operations handles VPN.",
               "reviewed_at" => sent |> hd() |> Map.fetch!("reviewed_at")
             }
           ]

    assert Regex.match?(
             ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z\z/,
             hd(sent)["reviewed_at"]
           )
  end

  test "saving needs a session, its CSRF token and the explicit save action", %{
    owner: owner,
    responses: responses
  } do
    Agent.update(responses, &Map.put(&1, @corrections_path, {200, saved()}))

    assert build_conn() |> post("/api/v1/learning/corrections", %{}) |> json_response(401)

    assert cookie_conn(owner)
           |> post("/api/v1/learning/corrections", %{})
           |> json_response(403)
           |> Map.fetch!("error") == "csrf_failed"

    refute_received {:learning_request, _, _, _}

    assert cookie_conn(owner)
           |> put_req_header("x-csrf-token", owner.auth.csrf_token)
           |> post("/api/v1/learning/corrections", %{"owner" => "someone-else"})
           |> json_response(422)
           |> Map.fetch!("error") == "invalid_learning_request"

    refute_received {:learning_request, _, _, _}

    assert cookie_conn(owner)
           |> put_req_header("x-csrf-token", owner.auth.csrf_token)
           |> post("/api/v1/learning/corrections", %{})
           |> json_response(200) == saved()

    owner_id = owner.user["user_id"]

    assert_receive {:learning_request, @corrections_path,
                    %{"owner" => ^owner_id, "apply" => true, "corrections" => []}, _}
  end

  test "AI refusals and malformed receipts cross as bounded public errors", %{
    owner: owner,
    responses: responses
  } do
    Agent.update(
      responses,
      &Map.put(&1, @corrections_path, {422, %{"detail" => "learning_corrections_too_few"}})
    )

    assert owner
           |> conn_for()
           |> post("/api/v1/learning/corrections", %{})
           |> json_response(422)
           |> Map.fetch!("error") == "learning_corrections_too_few"

    for receipt <- [
          Map.put(@preview, "status", "trained"),
          Map.put(@preview, "promotion_enabled", true),
          Map.put(saved(), "dataset", nil),
          Map.put(@preview, "usable", -1)
        ] do
      Agent.update(responses, &Map.put(&1, @corrections_path, {200, receipt}))

      assert owner
             |> conn_for()
             |> get("/api/v1/learning/corrections")
             |> json_response(503)
             |> Map.fetch!("error") == "learning_service_unavailable"
    end
  end

  test "a correction on a request too long for training is left out, not refused", %{
    owner: owner,
    reviewer: reviewer
  } do
    long = feedback(owner, String.duplicate("vpn ", 5_001), "Network Operations handles VPN.")
    decide(reviewer, long, "accepted")

    assert owner |> conn_for() |> get("/api/v1/learning/corrections") |> json_response(200)
    assert_receive {:learning_request, @corrections_path, %{"corrections" => []}, _}
  end

  defp saved, do: Map.merge(@preview, %{"status" => "saved", "dataset" => @saved_dataset})

  defp feedback(identity, request, correction) do
    job = completed_job(identity, request)

    body =
      %{"submission_id" => SubmissionTestSupport.identity(), "note" => "The answer was wrong"}
      |> then(&if(correction, do: Map.put(&1, "correction", correction), else: &1))

    identity
    |> conn_for()
    |> post("/api/v1/jobs/#{job.id}/feedback", body)
    |> json_response(201)
    |> Map.fetch!("feedback")
  end

  defp decide(reviewer, feedback, decision) do
    reviewer
    |> conn_for()
    |> post("/api/v1/feedback/#{feedback["feedback_id"]}/review", %{
      "decision" => decision,
      "reason" => "Checked against the runbook"
    })
    |> json_response(200)
  end

  defp completed_job(identity, request) do
    {:ok, job} =
      Jobs.create(%{
        user_id: identity.user["user_id"],
        conversation_id: identity.chat["chat_id"],
        message: request
      })

    {:ok, processing} = Job.claim(job, 60)
    {:ok, completed} = Job.transition(processing, "completed")

    {:ok, stored} =
      completed
      |> Job.put_result(%{"answer" => "The Service Desk handles it."})
      |> Jobs.update()

    stored
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

  defp conn_for(identity),
    do: build_conn() |> AuthTestSupport.bearer_conn(identity.auth.raw_token)

  defp cookie_conn(identity),
    do: put_req_cookie(build_conn(), RuntimeConfig.auth!().cookie_name, identity.auth.raw_token)
end
