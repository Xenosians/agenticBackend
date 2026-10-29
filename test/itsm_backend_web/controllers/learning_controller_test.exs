defmodule ItsmBackendWeb.LearningControllerTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.{ApiContract, AuthTestSupport}

  @catalog_path "/internal/v1/learning/catalog"
  @preflight_path "/internal/v1/learning/preflight"
  @runs_path "/internal/v1/learning/runs"
  @start_path "/internal/v1/learning/runs/start"
  @cancel_path "/internal/v1/learning/runs/cancel"
  @catalog %{
    "schema" => "learning-catalog.v2",
    "methods" => [
      %{
        "id" => "sft",
        "roles" => ["hub", "specialist"],
        "tuning" => ["full", "lora", "qlora"],
        "entrypoint" => "scripts/train_recipe.py",
        "requires" => "Reviewed examples and validation"
      },
      %{
        "id" => "dpo",
        "roles" => ["specialist"],
        "tuning" => ["qlora"],
        "entrypoint" => "scripts/train_preferences.py",
        "requires" => "Reviewed independent preferences"
      },
      %{
        "id" => "ppo",
        "roles" => ["hub"],
        "tuning" => ["qlora"],
        "entrypoint" => "scripts/train_ppo.py",
        "requires" => "Evaluated adapter and simulator episodes"
      }
    ],
    "models" => [],
    "datasets" => [],
    "promotion_enabled" => false
  }
  @selection %{
    "method" => "sft",
    "role" => "hub",
    "tuning" => "qlora",
    "model_id" => String.duplicate("a", 32),
    "dataset_id" => String.duplicate("b", 32),
    "dataset_sha256" => String.duplicate("c", 64)
  }
  @receipt %{
    "schema" => "learning-selection-preflight.v2",
    "status" => "ready",
    "preflight_sha256" => String.duplicate("d", 64),
    "method" => "sft",
    "role" => "hub",
    "tuning" => "qlora",
    "model" => %{
      "id" => @selection["model_id"],
      "backend" => "local",
      "source_kind" => "local",
      "state" => "ready"
    },
    "dataset" => %{
      "id" => @selection["dataset_id"],
      "sha256" => @selection["dataset_sha256"],
      "lineage_id" => String.duplicate("e", 32),
      "version" => 1,
      "train_count" => 8,
      "validation_count" => 2
    },
    "entrypoint" => "scripts/train_recipe.py",
    "blockers" => [],
    "later_gates" => ~w(fixed_evaluation_required separate_promotion_required),
    "model_loaded" => false,
    "live_tool_execution" => false,
    "promotion_enabled" => false
  }
  @run_request Map.put(@selection, "preflight_sha256", String.duplicate("d", 64))
  @run %{
    "schema" => "learning-run.v1",
    "run_id" => String.duplicate("f", 32),
    "state" => "running",
    "method" => "sft",
    "role" => "hub",
    "tuning" => "qlora",
    "model" => %{"id" => @selection["model_id"], "backend" => "local", "source_kind" => "local"},
    "dataset" => %{
      "id" => @selection["dataset_id"],
      "sha256" => @selection["dataset_sha256"],
      "version" => 1,
      "train_count" => 8,
      "validation_count" => 2
    },
    "preflight_sha256" => String.duplicate("d", 64),
    "progress" => %{"step" => 0, "max_steps" => 6},
    "metrics" => %{"train_loss" => nil, "validation_loss" => nil},
    "candidate_sha256" => nil,
    "error" => nil,
    "started_at" => "2026-10-29T07:00:00+00:00",
    "finished_at" => nil,
    "serving_changed" => false,
    "promotion_enabled" => false
  }

  setup do
    original = Application.get_env(:itsm_backend, :ai_service)
    original_token = Application.get_env(:itsm_backend, :internal_job_token)

    responses =
      start_supervised!(
        {Agent,
         fn ->
           %{
             @catalog_path => {200, @catalog},
             @preflight_path => {200, @receipt},
             @runs_path => {200, %{"schema" => "learning-runs.v1", "runs" => [@run]}},
             @start_path => {200, @run},
             @cancel_path =>
               {200,
                Map.merge(@run, %{
                  "state" => "cancelled",
                  "finished_at" => "2026-10-29T07:05:00+00:00"
                })}
           }
         end}
      )

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
      Keyword.put(original, :base_url, "http://127.0.0.1:#{port}")
    )

    Application.put_env(:itsm_backend, :internal_job_token, "learning-test-internal")

    on_exit(fn ->
      Application.put_env(:itsm_backend, :ai_service, original)
      Application.put_env(:itsm_backend, :internal_job_token, original_token)
    end)

    %{identity: AuthTestSupport.authenticated_identity!(), responses: responses}
  end

  test "the catalog is read for the signed-in owner only", %{identity: identity} do
    assert build_conn() |> bearer(identity) |> get("/api/v1/learning") |> json_response(200) ==
             @catalog

    owner = identity.user["user_id"]

    assert_receive {:learning_request, @catalog_path, %{"owner" => ^owner} = body,
                    ["learning-test-internal"]}

    assert map_size(body) == 1
  end

  test "a catalog read with arguments never reaches the AI service", %{identity: identity} do
    response =
      build_conn()
      |> bearer(identity)
      |> get("/api/v1/learning?owner=another-user")
      |> json_response(422)

    assert response["error"] == "invalid_learning_request"
    refute_received {:learning_request, _, _, _}
  end

  test "anonymous requests never reach the AI service" do
    assert build_conn() |> get("/api/v1/learning") |> json_response(401)
    assert build_conn() |> post("/api/v1/learning/preflight", @selection) |> json_response(401)
    refute_received {:learning_request, _, _, _}
  end

  test "a cookie session needs its CSRF token to check readiness", %{identity: identity} do
    assert json_response(
             post(cookie_conn(identity), "/api/v1/learning/preflight", @selection),
             403
           )[
             "error"
           ] == "csrf_failed"

    refute_received {:learning_request, _, _, _}

    assert cookie_conn(identity)
           |> put_req_header("x-csrf-token", identity.auth.csrf_token)
           |> post("/api/v1/learning/preflight", @selection)
           |> json_response(200) == @receipt

    owner = identity.user["user_id"]

    assert_receive {:learning_request, @preflight_path,
                    %{"owner" => ^owner, "selection" => @selection} = body,
                    ["learning-test-internal"]}

    assert map_size(body) == 2
  end

  test "the check forwards exactly the selection, never a client-chosen owner", %{
    identity: identity
  } do
    for body <- [
          Map.put(@selection, "owner", "another-user"),
          Map.put(@selection, "start_training", true),
          Map.delete(@selection, "dataset_sha256")
        ] do
      response =
        build_conn()
        |> bearer(identity)
        |> post("/api/v1/learning/preflight", body)
        |> json_response(422)

      assert response["error"] == "invalid_learning_request"
    end

    response =
      build_conn()
      |> bearer(identity)
      |> post("/api/v1/learning/preflight?owner=another-user", @selection)
      |> json_response(422)

    assert response["error"] == "invalid_learning_request"
    refute_received {:learning_request, _, _, _}
  end

  test "AI refusals cross as bounded public errors", %{identity: identity, responses: responses} do
    for {detail, code} <- [
          {"learning_dataset_superseded", "learning_dataset_superseded"},
          {"learning_resource_unavailable", "learning_resource_unavailable"},
          {[%{"loc" => ["body"], "msg" => "raw validation text"}], "invalid_learning_request"},
          {"raw upstream text that must stay private", "invalid_learning_request"}
        ] do
      Agent.update(responses, &Map.put(&1, @preflight_path, {422, %{"detail" => detail}}))

      response =
        build_conn()
        |> bearer(identity)
        |> post("/api/v1/learning/preflight", @selection)
        |> json_response(422)

      assert response["error"] == code
      assert is_binary(response["message"])
      refute inspect(response) =~ "raw"
    end
  end

  test "an unavailable AI service is never shown as an empty catalog", %{
    identity: identity,
    responses: responses
  } do
    for reply <- [
          {503, %{"detail" => "learning_service_unavailable"}},
          {200, ["not", "a", "catalog"]},
          {500, %{}}
        ] do
      Agent.update(responses, &Map.put(&1, @catalog_path, reply))
      response = build_conn() |> bearer(identity) |> get("/api/v1/learning") |> json_response(503)
      assert response["error"] == "learning_service_unavailable"
      assert response["retryable"] == true
    end
  end

  test "HTTP200 malformed or execution-enabling catalog maps are refused", %{
    identity: identity,
    responses: responses
  } do
    for body <- [
          %{},
          Map.put(@catalog, "schema", "wrong"),
          Map.put(@catalog, "execution_enabled", true),
          Map.put(@catalog, "methods", []),
          Map.put(@catalog, "private_debug", "must not escape")
        ] do
      Agent.update(responses, &Map.put(&1, @catalog_path, {200, body}))
      reply = build_conn() |> bearer(identity) |> get("/api/v1/learning") |> json_response(503)
      assert reply["error"] == "learning_service_unavailable"
      refute inspect(reply) =~ "must not escape"
    end
  end

  test "preflight receipts must bind the exact selection and keep promotion disabled",
       %{identity: identity, responses: responses} do
    for body <- [
          %{},
          Map.put(@receipt, "status", "running"),
          Map.put(@receipt, "model_loaded", true),
          Map.put(@receipt, "promotion_enabled", true),
          Map.put(@receipt, "blockers", ["local_weights_unavailable"]),
          Map.merge(@receipt, %{"status" => "blocked", "blockers" => []}),
          Map.put(@receipt, "later_gates", []),
          put_in(@receipt, ["model", "id"], String.duplicate("f", 32)),
          put_in(@receipt, ["dataset", "sha256"], String.duplicate("f", 64)),
          Map.put(@receipt, "method", "ppo"),
          # An outbound connection can never be ready to train.
          @receipt
          |> put_in(["model", "backend"], "http")
          |> put_in(["model", "source_kind"], "outbound")
        ] do
      Agent.update(responses, &Map.put(&1, @preflight_path, {200, body}))

      reply =
        build_conn()
        |> bearer(identity)
        |> post("/api/v1/learning/preflight", @selection)
        |> json_response(503)

      assert reply["error"] == "learning_service_unavailable"
    end
  end

  test "valid ready and blocked receipts preserve their method gates", %{
    identity: identity,
    responses: responses
  } do
    for {method, role, tuning, entrypoint, backend, source, blockers} <- [
          {"sft", "specialist", "lora", "scripts/train_recipe.py", "uploaded", "local", []},
          {"sft", "hub", "qlora", "scripts/train_recipe.py", "local", "local",
           ["local_weights_unavailable"]},
          {"sft", "hub", "full", "scripts/train_recipe.py", "local", "local",
           ["full_tuning_not_offered"]},
          {"sft", "hub", "qlora", "scripts/train_recipe.py", "http", "outbound",
           ["outbound_connection_is_inference_only"]},
          {"dpo", "specialist", "qlora", "scripts/train_preferences.py", "uploaded", "local",
           ["host_dispatch_not_integrated", "reviewed_preference_partitions_required"]},
          {"ppo", "hub", "qlora", "scripts/train_ppo.py", "local", "local",
           [
             "evaluated_adapter_checkpoint_required",
             "host_dispatch_not_integrated",
             "independent_simulator_episodes_required"
           ]}
        ] do
      selection = Map.merge(@selection, %{"method" => method, "role" => role, "tuning" => tuning})

      receipt =
        @receipt
        |> Map.merge(%{
          "method" => method,
          "role" => role,
          "tuning" => tuning,
          "entrypoint" => entrypoint,
          "status" => if(blockers == [], do: "ready", else: "blocked"),
          "blockers" => blockers
        })
        |> put_in(["model", "backend"], backend)
        |> put_in(["model", "source_kind"], source)

      Agent.update(responses, &Map.put(&1, @preflight_path, {200, receipt}))

      assert build_conn()
             |> bearer(identity)
             |> post("/api/v1/learning/preflight", selection)
             |> json_response(200) == receipt
    end
  end

  test "catalog resource identities and dataset membership counts are validated", %{
    identity: identity,
    responses: responses
  } do
    model =
      Map.merge(@receipt["model"], %{
        "name" => "Owned upload",
        "backend" => "uploaded",
        "training_available" => false
      })

    dataset =
      Map.merge(@receipt["dataset"], %{
        "name" => "Reviewed data",
        "state" => "ready",
        "purpose" => "training",
        "superseded_by" => nil
      })

    catalog = Map.merge(@catalog, %{"models" => [model], "datasets" => [dataset]})
    Agent.update(responses, &Map.put(&1, @catalog_path, {200, catalog}))

    assert build_conn() |> bearer(identity) |> get("/api/v1/learning") |> json_response(200) ==
             catalog

    for broken <- [
          Map.put(catalog, "models", [Map.put(model, "source_kind", "outbound")]),
          Map.put(catalog, "models", [
            Map.merge(model, %{
              "backend" => "http",
              "source_kind" => "outbound",
              "training_available" => true
            })
          ]),
          Map.put(catalog, "datasets", [Map.put(dataset, "validation_count", 0)]),
          Map.put(catalog, "datasets", [Map.put(dataset, "sha256", "broken")]),
          Map.put(catalog, "models", [model, model])
        ] do
      Agent.update(responses, &Map.put(&1, @catalog_path, {200, broken}))
      assert build_conn() |> bearer(identity) |> get("/api/v1/learning") |> json_response(503)
    end
  end

  test "the readiness check declares its exact arguments" do
    contract =
      Enum.find(ApiContract.audit!(), &(&1.path == "/api/v1/learning/preflight"))

    assert Enum.sort(contract.required_body_params) == Enum.sort(Map.keys(@selection))
    assert contract.optional_body_params == []
  end

  test "runs are listed for the signed-in owner only", %{identity: identity} do
    assert build_conn() |> bearer(identity) |> get("/api/v1/learning/runs") |> json_response(200) ==
             %{"schema" => "learning-runs.v1", "runs" => [@run]}

    owner = identity.user["user_id"]

    assert_receive {:learning_request, @runs_path, %{"owner" => ^owner} = body,
                    ["learning-test-internal"]}

    assert map_size(body) == 1

    assert build_conn()
           |> bearer(identity)
           |> get("/api/v1/learning/runs?owner=another-user")
           |> json_response(422)

    refute_received {:learning_request, _, _, _}
  end

  test "starting a run needs a session, its CSRF token and exactly the checked selection", %{
    identity: identity
  } do
    assert build_conn() |> post("/api/v1/learning/runs", @run_request) |> json_response(401)

    assert json_response(post(cookie_conn(identity), "/api/v1/learning/runs", @run_request), 403)[
             "error"
           ] == "csrf_failed"

    for body <- [
          Map.put(@run_request, "owner", "another-user"),
          Map.put(@run_request, "max_steps", 4000),
          Map.delete(@run_request, "preflight_sha256")
        ] do
      assert build_conn()
             |> bearer(identity)
             |> post("/api/v1/learning/runs", body)
             |> json_response(422)
             |> Map.fetch!("error") == "invalid_learning_request"
    end

    refute_received {:learning_request, _, _, _}

    assert cookie_conn(identity)
           |> put_req_header("x-csrf-token", identity.auth.csrf_token)
           |> post("/api/v1/learning/runs", @run_request)
           |> json_response(200) == @run

    owner = identity.user["user_id"]

    assert_receive {:learning_request, @start_path,
                    %{"owner" => ^owner, "run" => @run_request} = body,
                    ["learning-test-internal"]}

    assert map_size(body) == 2
  end

  test "a run receipt must match the request and never claim serving or promotion", %{
    identity: identity,
    responses: responses
  } do
    for body <- [
          %{},
          Map.put(@run, "serving_changed", true),
          Map.put(@run, "promotion_enabled", true),
          Map.put(@run, "state", "promoted"),
          Map.put(@run, "preflight_sha256", String.duplicate("0", 64)),
          put_in(@run, ["model", "id"], String.duplicate("0", 32)),
          put_in(@run, ["dataset", "sha256"], String.duplicate("0", 64)),
          put_in(@run, ["progress", "step"], 7),
          Map.put(@run, "candidate_sha256", "not-a-digest"),
          Map.put(@run, "error", "Traceback: private detail"),
          Map.put(@run, "private_debug", "must not escape")
        ] do
      Agent.update(responses, &Map.put(&1, @start_path, {200, body}))

      reply =
        build_conn()
        |> bearer(identity)
        |> post("/api/v1/learning/runs", @run_request)
        |> json_response(503)

      assert reply["error"] == "learning_service_unavailable"
      refute inspect(reply) =~ "private"
    end

    completed =
      Map.merge(@run, %{
        "run_id" => String.duplicate("e", 32),
        "state" => "completed",
        "progress" => %{"step" => 6, "max_steps" => 6},
        "metrics" => %{"train_loss" => 0.5, "validation_loss" => 0.75},
        "candidate_sha256" => String.duplicate("9", 64),
        "finished_at" => "2026-10-29T07:10:00+00:00"
      })

    for {list, ok?} <- [
          {[completed, @run], true},
          {[Map.put(completed, "candidate_sha256", nil)], false},
          {[Map.merge(@run, %{"state" => "failed", "error" => "insufficient_gpu_memory"})],
           false},
          {[
             Map.merge(@run, %{
               "state" => "failed",
               "error" => "insufficient_gpu_memory",
               "finished_at" => "2026-10-29T07:10:00+00:00"
             })
           ], true},
          {[
             Map.merge(@run, %{
               "state" => "failed",
               "error" => "Traceback: private detail",
               "finished_at" => "2026-10-29T07:10:00+00:00"
             })
           ], false},
          {[put_in(@run, ["model", "backend"], "http")], false},
          {[put_in(@run, ["model", "source_kind"], "outbound")], false},
          {for(index <- 1..21, do: Map.put(@run, "run_id", run_id(index))), false},
          {for(index <- 1..20, do: Map.put(@run, "run_id", run_id(index))), true},
          {[@run, @run], false}
        ] do
      Agent.update(
        responses,
        &Map.put(&1, @runs_path, {200, %{"schema" => "learning-runs.v1", "runs" => list}})
      )

      status = if ok?, do: 200, else: 503

      assert build_conn()
             |> bearer(identity)
             |> get("/api/v1/learning/runs")
             |> json_response(status)
    end
  end

  test "run refusals keep their code and a busy host is a conflict", %{
    identity: identity,
    responses: responses
  } do
    for {status, detail, public_status, code} <- [
          {409, "learning_host_busy", 409, "learning_host_busy"},
          {422, "learning_check_changed", 422, "learning_check_changed"},
          {422, "learning_run_not_ready", 422, "learning_run_not_ready"},
          {422, "raw private text", 422, "invalid_learning_request"}
        ] do
      Agent.update(responses, &Map.put(&1, @start_path, {status, %{"detail" => detail}}))

      reply =
        build_conn()
        |> bearer(identity)
        |> post("/api/v1/learning/runs", @run_request)
        |> json_response(public_status)

      assert reply["error"] == code
      refute inspect(reply) =~ "raw"
    end
  end

  test "cancelling forwards only the run identity for the signed-in owner", %{
    identity: identity,
    responses: responses
  } do
    run_id = @run["run_id"]
    path = "/api/v1/learning/runs/#{run_id}/cancel"

    assert json_response(post(cookie_conn(identity), path, %{}), 403)["error"] == "csrf_failed"

    for bad <- ["/api/v1/learning/runs/../cancel", "/api/v1/learning/runs/NOT-AN-ID/cancel"] do
      assert build_conn() |> bearer(identity) |> post(bad, %{}) |> json_response(422)
    end

    refute_received {:learning_request, _, _, _}

    reply = build_conn() |> bearer(identity) |> post(path, %{}) |> json_response(200)
    assert reply["state"] == "cancelled"
    owner = identity.user["user_id"]

    assert_receive {:learning_request, @cancel_path,
                    %{"owner" => ^owner, "run_id" => ^run_id} = body, ["learning-test-internal"]}

    assert map_size(body) == 2

    Agent.update(
      responses,
      &Map.put(&1, @cancel_path, {200, Map.put(@run, "run_id", String.duplicate("0", 32))})
    )

    assert build_conn() |> bearer(identity) |> post(path, %{}) |> json_response(503)

    Agent.update(
      responses,
      &Map.put(&1, @cancel_path, {404, %{"detail" => "learning_run_unavailable"}})
    )

    assert build_conn()
           |> bearer(identity)
           |> post(path, %{})
           |> json_response(404)
           |> Map.fetch!("error") ==
             "learning_run_unavailable"
  end

  defp bearer(conn, identity), do: AuthTestSupport.bearer_conn(conn, identity.auth.raw_token)

  defp run_id(index),
    do: index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")

  defp cookie_conn(identity),
    do: put_req_cookie(build_conn(), RuntimeConfig.auth!().cookie_name, identity.auth.raw_token)
end
