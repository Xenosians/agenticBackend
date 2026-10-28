defmodule ItsmBackendWeb.WorkflowControllerTest do
  @moduledoc """
  Saved workflows (SRS 1.9 FR-084, V19-07): owner-scoped, versioned
  definitions whose runs are ordinary durable jobs. A run binds the exact saved
  version, so approvals, idempotency and restart recovery are the job's own.
  """
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.{Chats, Jobs, RuntimeConfig, SubmissionTestSupport, Surreal, Workflows}
  alias ItsmBackendWeb.{ApiContract, AuthTestSupport}

  @definition %{
    "version" => 1,
    "steps" => [
      %{
        "id" => "account",
        "capability" => "account_create",
        "grounded_arguments" => %{"given_name" => ["Reviewed"]},
        "after_success_of" => nil
      },
      %{
        "id" => "ticket",
        "capability" => "ticket_create",
        "grounded_arguments" => %{"project_key" => ["SUP"]},
        "after_success_of" => "account"
      }
    ]
  }
  @layout %{"account" => %{"x" => 40, "y" => 60}, "ticket" => %{"x" => 320, "y" => 60}}

  setup do
    %{owner: AuthTestSupport.authenticated_identity!()}
  end

  test "a saved workflow is listed and read only by its owner", %{owner: owner} do
    other = AuthTestSupport.authenticated_identity!()
    saved = create(owner, "Onboard a contractor")

    assert saved["name"] == "Onboard a contractor"
    assert saved["version"] == 1
    assert saved["definition"] == @definition
    assert saved["layout"] == @layout
    assert saved["definition_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert saved["execution"] == "durable_job"

    assert [%{"workflow_id" => id, "version" => 1}] =
             owner
             |> bearer()
             |> get("/api/v1/workflows")
             |> json_response(200)
             |> Map.get("workflows")

    assert id == saved["workflow_id"]

    assert other |> bearer() |> get("/api/v1/workflows") |> json_response(200) == %{
             "workflows" => []
           }

    assert other
           |> bearer()
           |> get("/api/v1/workflows/#{id}")
           |> json_response(404)
           |> Map.get("error") ==
             "workflow_not_found"
  end

  test "saving a new version requires the version the editor started from", %{owner: owner} do
    saved = create(owner, "Draft")

    changed =
      put_in(@definition, ["steps", Access.at(1), "grounded_arguments"], %{
        "project_key" => ["OPS"]
      })

    updated =
      owner
      |> bearer()
      |> put("/api/v1/workflows/#{saved["workflow_id"]}", %{
        "name" => "Draft",
        "definition" => changed,
        "layout" => @layout,
        "base_version" => 1
      })
      |> json_response(200)
      |> Map.fetch!("workflow")

    assert updated["version"] == 2
    assert updated["definition"] == changed
    assert updated["definition_sha256"] != saved["definition_sha256"]

    stale =
      owner
      |> bearer()
      |> put("/api/v1/workflows/#{saved["workflow_id"]}", %{
        "name" => "Draft",
        "definition" => @definition,
        "layout" => @layout,
        "base_version" => 1
      })
      |> json_response(409)

    assert stale["error"] == "workflow_version_conflict"
    assert get_workflow(owner, saved["workflow_id"])["version"] == 2
  end

  test "invalid definitions, layouts and names are refused before saving", %{owner: owner} do
    cycle = put_in(@definition, ["steps", Access.at(0), "after_success_of"], "ticket")
    duplicate = put_in(@definition, ["steps", Access.at(1), "capability"], "account_create")

    secret_field =
      put_in(@definition, ["steps", Access.at(0), "grounded_arguments"], %{"bad-name" => ["x"]})

    for {name, definition, layout} <- [
          {"Cycle", cycle, @layout},
          {"Duplicate", duplicate, @layout},
          {"Bad field", secret_field, @layout},
          {"Missing layout node", @definition, Map.delete(@layout, "ticket")},
          {"Unknown layout node", @definition, Map.put(@layout, "other", %{"x" => 1, "y" => 1})},
          {"Bad coordinate", @definition, put_in(@layout, ["ticket", "x"], "far")},
          {"   ", @definition, @layout}
        ] do
      response =
        owner
        |> bearer()
        |> post("/api/v1/workflows", %{
          "name" => name,
          "definition" => definition,
          "layout" => layout
        })
        |> json_response(422)

      assert response["error"] == "invalid_workflow", name
    end

    assert owner |> bearer() |> get("/api/v1/workflows") |> json_response(200) == %{
             "workflows" => []
           }
  end

  test "a run is one durable job bound to the exact saved version", %{owner: owner} do
    saved = create(owner, "Onboard a contractor")
    submission = SubmissionTestSupport.identity()
    body = run_body(saved, submission, "Onboard Dana Reviewed into SUP")

    run = owner |> bearer() |> post(run_path(saved), body) |> json_response(202)

    assert run["status"] == "pending"
    assert run["workflow_id"] == saved["workflow_id"]
    assert run["workflow_version"] == 1
    assert run["submission_id"] == submission
    assert run["workflow_contract"] == @definition
    assert run["workflow_contract_hash"] == saved["definition_sha256"]

    {:ok, job} = Jobs.get(run["job_id"])
    assert job.user_id == owner.user["user_id"]
    assert job.conversation_id == run["chat_id"]
    assert job.message == "Onboard Dana Reviewed into SUP"
    assert job.workflow_contract == @definition
    assert job.workflow_contract_hash == saved["definition_sha256"]

    # The run gets its own chat so its history and approvals stay together.
    chats = owner |> bearer() |> get("/api/v1/chats") |> json_response(200) |> Map.get("chats")

    assert Enum.any?(
             chats,
             &(&1["chat_id"] == run["chat_id"] and &1["title"] == "Onboard a contractor")
           )

    # Retrying the same submission returns the same job, never a second run.
    again = owner |> bearer() |> post(run_path(saved), body) |> json_response(202)
    assert again["job_id"] == run["job_id"]
    assert again["chat_id"] == run["chat_id"]

    # ...and never leaves a second, empty chat behind.
    chats = owner |> bearer() |> get("/api/v1/chats") |> json_response(200) |> Map.get("chats")
    assert Enum.count(chats, &(&1["title"] == "Onboard a contractor")) == 1

    changed = Map.put(body, "message", "Something else")

    assert owner
           |> bearer()
           |> post(run_path(saved), changed)
           |> json_response(409)
           |> Map.get("error") ==
             "submission_conflict"

    # Run history lists the one job with its live status, newest first.
    assert [listed] =
             owner |> bearer() |> get(run_path(saved)) |> json_response(200) |> Map.fetch!("runs")

    assert listed["job_id"] == run["job_id"]
    assert listed["chat_id"] == run["chat_id"]
    assert listed["workflow_version"] == 1
    assert listed["status"] == "pending"

    other = AuthTestSupport.authenticated_identity!()

    assert other |> bearer() |> get(run_path(saved)) |> json_response(404) |> Map.get("error") ==
             "workflow_not_found"
  end

  test "a run of an outdated version is refused", %{owner: owner} do
    saved = create(owner, "Draft")

    owner
    |> bearer()
    |> put("/api/v1/workflows/#{saved["workflow_id"]}", %{
      "name" => "Draft v2",
      "definition" => @definition,
      "layout" => @layout,
      "base_version" => 1
    })
    |> json_response(200)

    response =
      owner
      |> bearer()
      |> post(run_path(saved), run_body(saved, SubmissionTestSupport.identity(), "Run it"))
      |> json_response(409)

    assert response["error"] == "workflow_version_conflict"
  end

  test "another owner cannot run, change or archive a workflow", %{owner: owner} do
    other = AuthTestSupport.authenticated_identity!()
    saved = create(owner, "Private")
    id = saved["workflow_id"]

    assert other
           |> bearer()
           |> post(run_path(saved), run_body(saved, SubmissionTestSupport.identity(), "Run it"))
           |> json_response(404)
           |> Map.get("error") == "workflow_not_found"

    assert other
           |> bearer()
           |> put("/api/v1/workflows/#{id}", %{
             "name" => "Taken",
             "definition" => @definition,
             "layout" => @layout,
             "base_version" => 1
           })
           |> json_response(404)
           |> Map.get("error") == "workflow_not_found"

    assert other
           |> bearer()
           |> delete("/api/v1/workflows/#{id}")
           |> json_response(404)
           |> Map.get("error") ==
             "workflow_not_found"

    assert get_workflow(owner, id)["version"] == 1
  end

  test "archiving hides the workflow but keeps the jobs it ran", %{owner: owner} do
    saved = create(owner, "Short lived")

    run =
      owner
      |> bearer()
      |> post(run_path(saved), run_body(saved, SubmissionTestSupport.identity(), "Run it"))
      |> json_response(202)

    assert owner
           |> bearer()
           |> delete("/api/v1/workflows/#{saved["workflow_id"]}")
           |> json_response(200) ==
             %{"archived" => true, "workflow_id" => saved["workflow_id"]}

    assert owner |> bearer() |> get("/api/v1/workflows") |> json_response(200) == %{
             "workflows" => []
           }

    assert owner
           |> bearer()
           |> get("/api/v1/workflows/#{saved["workflow_id"]}")
           |> json_response(404)
           |> Map.get("error") == "workflow_not_found"

    assert owner
           |> bearer()
           |> post(
             run_path(saved),
             run_body(saved, SubmissionTestSupport.identity(), "Run again")
           )
           |> json_response(404)
           |> Map.get("error") == "workflow_not_found"

    assert {:ok, _job} = Jobs.get(run["job_id"])
  end

  test "cookie sessions need CSRF for every change and anonymous requests are refused", %{
    owner: owner
  } do
    saved = create(owner, "Guarded")

    cookie =
      build_conn() |> put_req_cookie(RuntimeConfig.auth!().cookie_name, owner.auth.raw_token)

    body = %{"name" => "X", "definition" => @definition, "layout" => @layout}

    assert cookie |> post("/api/v1/workflows", body) |> json_response(403) == %{
             "error" => "csrf_failed"
           }

    assert cookie
           |> post(run_path(saved), run_body(saved, SubmissionTestSupport.identity(), "Run it"))
           |> json_response(403) == %{"error" => "csrf_failed"}

    assert cookie |> delete("/api/v1/workflows/#{saved["workflow_id"]}") |> json_response(403) ==
             %{"error" => "csrf_failed"}

    assert build_conn() |> get("/api/v1/workflows") |> json_response(401)

    assert cookie
           |> put_req_header("x-csrf-token", owner.auth.csrf_token)
           |> post("/api/v1/workflows", body)
           |> json_response(201)
  end

  test "routes declare their exact arguments" do
    contracts = ApiContract.audit!()
    find = fn method, path -> Enum.find(contracts, &(&1.method == method and &1.path == path)) end

    assert find.("POST", "/api/v1/workflows").required_body_params == [
             "name",
             "definition",
             "layout"
           ]

    assert find.("PUT", "/api/v1/workflows/:id").required_body_params ==
             ["name", "definition", "layout", "base_version"]

    assert find.("POST", "/api/v1/workflows/:id/runs").required_body_params ==
             ["version", "submission_id", "message"]
  end

  test "a run identity cannot be relabelled as another workflow or version", %{owner: owner} do
    first = create(owner, "First workflow")
    second = create(owner, "Second workflow with the same definition")
    submission = SubmissionTestSupport.identity()
    body = run_body(first, submission, "Run the saved request")
    original = owner |> bearer() |> post(run_path(first), body) |> json_response(202)

    assert owner
           |> bearer()
           |> post(run_path(second), body)
           |> json_response(409)
           |> Map.get("error") ==
             "submission_conflict"

    updated =
      owner
      |> bearer()
      |> put("/api/v1/workflows/#{first["workflow_id"]}", %{
        "name" => "Renamed",
        "definition" => @definition,
        "layout" => @layout,
        "base_version" => 1
      })
      |> json_response(200)
      |> Map.fetch!("workflow")

    assert owner
           |> bearer()
           |> post(run_path(updated), Map.put(body, "version", 2))
           |> json_response(409)
           |> Map.get("error") ==
             "submission_conflict"

    assert [run] =
             owner |> bearer() |> get(run_path(first)) |> json_response(200) |> Map.fetch!("runs")

    assert run["job_id"] == original["job_id"] and run["workflow_version"] == 1
    assert owner |> bearer() |> get(run_path(second)) |> json_response(200) == %{"runs" => []}
  end

  test "an exact retry returns its original binding after edit and archive", %{owner: owner} do
    saved = create(owner, "Original")
    submission = SubmissionTestSupport.identity()
    body = run_body(saved, submission, "Original request")
    first = owner |> bearer() |> post(run_path(saved), body) |> json_response(202)

    owner
    |> bearer()
    |> put("/api/v1/workflows/#{saved["workflow_id"]}", %{
      "name" => "Changed",
      "definition" => @definition,
      "layout" => @layout,
      "base_version" => 1
    })
    |> json_response(200)

    assert owner |> bearer() |> post(run_path(saved), body) |> json_response(202) == first
    owner |> bearer() |> delete("/api/v1/workflows/#{saved["workflow_id"]}") |> json_response(200)
    assert owner |> bearer() |> post(run_path(saved), body) |> json_response(202) == first

    assert owner
           |> bearer()
           |> post(run_path(saved), Map.put(body, "message", "A changed request"))
           |> json_response(409)
  end

  test "concurrent first attempts create one run chat and preserve one job", %{owner: owner} do
    saved = create(owner, "Concurrent run")
    body = run_body(saved, SubmissionTestSupport.identity(), "Run once")

    results =
      1..8
      |> Task.async_stream(fn _ -> Workflows.run(owner.user, saved["workflow_id"], body) end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.any?(results, &match?({:ok, _, _, _}, &1))

    for result <- results do
      assert match?({:ok, _, _, _}, result) or result == {:error, :run_outcome_unknown}
    end

    assert {:ok, _, job, _} = Workflows.run(owner.user, saved["workflow_id"], body)
    {:ok, chats} = Chats.list(owner.user)
    assert [%{"chat_id" => chat_id}] = Enum.filter(chats, &(&1["title"] == "Concurrent run"))
    assert chat_id == job.conversation_id
    {:ok, jobs} = Jobs.list_by_conversation(owner.user["user_id"], chat_id, 20)
    assert Enum.map(jobs, & &1.id) == [job.id]
  end

  test "invalid submissions are refused before allocating a chat", %{owner: owner} do
    saved = create(owner, "Invalid submission")

    assert owner
           |> bearer()
           |> post(run_path(saved), run_body(saved, "not-a-uuid", "Run once"))
           |> json_response(422)

    {:ok, chats} = Chats.list(owner.user)
    refute Enum.any?(chats, &(&1["title"] == "Invalid submission"))
  end

  test "a retry never resets terminal job state or attempt count", %{owner: owner} do
    saved = create(owner, "Terminal retry")
    submission = SubmissionTestSupport.identity()
    body = run_body(saved, submission, "Run once")
    initial = owner |> bearer() |> post(run_path(saved), body) |> json_response(202)
    {:ok, job} = Jobs.get(initial["job_id"])

    {:ok, _} =
      Jobs.update(%{
        job
        | status: "outcome_unknown",
          attempts: 3,
          error: "Requires reconciliation"
      })

    retried = owner |> bearer() |> post(run_path(saved), body) |> json_response(202)
    assert retried["job_id"] == initial["job_id"] and retried["status"] == "outcome_unknown"
    {:ok, stored} = Jobs.get(initial["job_id"])
    assert stored.attempts == 3 and stored.error == "Requires reconciliation"
  end

  test "a durably admitted request can resume its exact job after the workflow changes", %{
    owner: owner
  } do
    saved = create(owner, "Admitted snapshot")
    submission = SubmissionTestSupport.identity()
    body = run_body(saved, submission, "Original intent")

    {:ok, expected} =
      ItsmBackend.Jobs.Job.new(%{
        "user_id" => owner.user["user_id"],
        "message" => body["message"],
        "submission_id" => submission
      })

    assert {:ok, binding} =
             ItsmBackend.Workflows.SurrealStore.claim_run(
               owner.user["user_id"],
               submission,
               saved,
               body["message"],
               expected.id
             )

    assert binding["job_id"] == nil
    assert {:error, _} = Jobs.get(expected.id)

    owner |> bearer() |> delete("/api/v1/workflows/#{saved["workflow_id"]}") |> json_response(200)
    run = owner |> bearer() |> post(run_path(saved), body) |> json_response(202)
    assert run["job_id"] == expected.id and run["workflow_version"] == 1
    assert run["workflow_contract"] == @definition
    {:ok, stored} = Jobs.get(expected.id)
    assert stored.conversation_id == binding["chat_id"]
  end

  test "legacy run records without immutable bindings require reconciliation", %{owner: owner} do
    saved = create(owner, "Legacy")
    submission = SubmissionTestSupport.identity()
    {:ok, chat} = Chats.create(owner.user, %{"title" => "Legacy run"})

    id =
      :crypto.hash(:sha256, Jason.encode!(["workflow-run-v1", owner.user["user_id"], submission]))
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)

    assert {:ok, _} =
             Surreal.query("CREATE ONLY type::record('workflow_run', $id) CONTENT $record;", %{
               "id" => id,
               "record" => %{
                 "user_id" => owner.user["user_id"],
                 "submission_id" => submission,
                 "chat_id" => chat["chat_id"],
                 "workflow_id" => saved["workflow_id"],
                 "workflow_version" => 1,
                 "job_id" => nil
               }
             })

    response =
      owner
      |> bearer()
      |> post(run_path(saved), run_body(saved, submission, "Run once"))
      |> json_response(503)

    assert response["error"] == "workflow_unavailable"
    {:ok, jobs} = Jobs.list_by_conversation(owner.user["user_id"], chat["chat_id"], 20)
    assert jobs == []
  end

  defp create(owner, name) do
    owner
    |> bearer()
    |> post("/api/v1/workflows", %{
      "name" => name,
      "definition" => @definition,
      "layout" => @layout
    })
    |> json_response(201)
    |> Map.fetch!("workflow")
  end

  defp get_workflow(owner, id),
    do:
      owner
      |> bearer()
      |> get("/api/v1/workflows/#{id}")
      |> json_response(200)
      |> Map.fetch!("workflow")

  defp run_body(saved, submission, message),
    do: %{"version" => saved["version"], "submission_id" => submission, "message" => message}

  defp run_path(saved), do: "/api/v1/workflows/#{saved["workflow_id"]}/runs"
  defp bearer(identity), do: AuthTestSupport.bearer_conn(build_conn(), identity.auth.raw_token)
end
