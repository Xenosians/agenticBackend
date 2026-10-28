defmodule ItsmBackendWeb.LearningControllerTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.{ApiContract, AuthTestSupport}

  @catalog_path "/internal/v1/learning/catalog"
  @preflight_path "/internal/v1/learning/preflight"
  @catalog %{
    "schema" => "learning-catalog.v1",
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
    "execution_enabled" => false,
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
    "schema" => "learning-selection-preflight.v1",
    "status" => "blocked",
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
    "resource_state" => "unknown",
    "blockers" =>
      Enum.sort(
        ~w(trusted_model_identity_required trusted_training_configuration_required fixed_evaluation_required resource_unknown host_dispatch_not_integrated separate_promotion_required)
      ),
    "execution_enabled" => false,
    "model_loaded" => false,
    "live_tool_execution" => false,
    "promotion_enabled" => false
  }

  setup do
    original = Application.get_env(:itsm_backend, :ai_service)
    original_token = Application.get_env(:itsm_backend, :internal_job_token)

    responses =
      start_supervised!(
        {Agent, fn -> %{@catalog_path => {200, @catalog}, @preflight_path => {200, @receipt}} end}
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

  test "preflight receipts must bind the exact selection and keep every execution gate disabled",
       %{identity: identity, responses: responses} do
    for body <- [
          %{},
          Map.put(@receipt, "status", "running"),
          Map.put(@receipt, "model_loaded", true),
          Map.put(@receipt, "promotion_enabled", true),
          Map.put(@receipt, "blockers", []),
          put_in(@receipt, ["model", "id"], String.duplicate("f", 32)),
          put_in(@receipt, ["dataset", "sha256"], String.duplicate("f", 64)),
          Map.put(@receipt, "method", "ppo")
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

  test "valid local uploads and outbound inspection receipts preserve their method gates", %{
    identity: identity,
    responses: responses
  } do
    for {method, role, entrypoint, backend, source} <- [
          {"sft", "specialist", "scripts/train_recipe.py", "uploaded", "local"},
          {"sft", "hub", "scripts/train_recipe.py", "http", "outbound"},
          {"dpo", "specialist", "scripts/train_preferences.py", "uploaded", "local"},
          {"ppo", "hub", "scripts/train_ppo.py", "local", "local"}
        ] do
      selection = Map.merge(@selection, %{"method" => method, "role" => role})

      method_blockers =
        case method do
          "dpo" ->
            ["reviewed_preference_partitions_required"]

          "ppo" ->
            ["evaluated_adapter_checkpoint_required", "independent_simulator_episodes_required"]

          _ ->
            []
        end

      outbound_blockers =
        if source == "outbound", do: ["outbound_connection_is_inference_only"], else: []

      receipt =
        @receipt
        |> Map.merge(%{"method" => method, "role" => role, "entrypoint" => entrypoint})
        |> put_in(["model", "backend"], backend)
        |> put_in(["model", "source_kind"], source)
        |> Map.put(
          "blockers",
          Enum.sort(@receipt["blockers"] ++ method_blockers ++ outbound_blockers)
        )

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

  defp bearer(conn, identity), do: AuthTestSupport.bearer_conn(conn, identity.auth.raw_token)

  defp cookie_conn(identity),
    do: put_req_cookie(build_conn(), RuntimeConfig.auth!().cookie_name, identity.auth.raw_token)
end
