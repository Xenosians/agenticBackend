defmodule ItsmBackendWeb.TopologyControllerTest do
  @moduledoc """
  Saved infrastructure topologies and engineering reads (SRS 1.9 FR-093, V19-09).

  A topology is the owner's desired graph, saved as versions. Drift sends one
  exact saved version to the AI service, which only observes and compares.
  Netlist inspection forwards text only. Nothing here can change a device.
  """
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.{ApiContract, AuthTestSupport}

  @design %{
    "nodes" => [
      %{
        "id" => "container:itsm-surrealdb",
        "kind" => "container",
        "label" => "Database",
        "properties" => %{"state" => "running"}
      },
      %{
        "id" => "endpoint:phoenix",
        "kind" => "service_endpoint",
        "label" => "Backend",
        "properties" => %{"up" => true}
      }
    ],
    "edges" => [
      %{
        "from" => "endpoint:phoenix",
        "to" => "container:itsm-surrealdb",
        "relation" => "depends_on"
      }
    ]
  }
  @layout %{
    "container:itsm-surrealdb" => %{"x" => 40, "y" => 40},
    "endpoint:phoenix" => %{"x" => 300, "y" => 40}
  }
  @drift_path "/internal/v1/engineering/topology/drift"
  @netlist_path "/internal/v1/engineering/netlist"

  setup do
    original = Application.get_env(:itsm_backend, :ai_service)
    original_token = Application.get_env(:itsm_backend, :internal_job_token)

    responses =
      start_supervised!(
        {Agent,
         fn -> %{@drift_path => {200, :echo_drift}, @netlist_path => {200, netlist_report()}} end}
      )

    server =
      start_supervised!(
        {Bandit,
         plug: {ItsmBackendWeb.EngineeringProbePlug, {self(), responses}},
         port: 0,
         ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    Application.put_env(
      :itsm_backend,
      :ai_service,
      Keyword.put(original, :base_url, "http://127.0.0.1:#{port}")
    )

    Application.put_env(:itsm_backend, :internal_job_token, "engineering-test-internal")

    on_exit(fn ->
      Application.put_env(:itsm_backend, :ai_service, original)
      Application.put_env(:itsm_backend, :internal_job_token, original_token)
    end)

    %{owner: AuthTestSupport.authenticated_identity!(), responses: responses}
  end

  test "a saved topology is listed and read only by its owner", %{owner: owner} do
    other = AuthTestSupport.authenticated_identity!()
    saved = create(owner, "Lab stack")

    assert saved["name"] == "Lab stack"
    assert saved["version"] == 1
    assert saved["design"] == @design
    assert saved["layout"] == @layout
    assert saved["design_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert saved["state_kind"] == "desired"

    assert [%{"topology_id" => id, "version" => 1, "name" => "Lab stack"}] =
             owner
             |> bearer()
             |> get("/api/v1/topologies")
             |> json_response(200)
             |> Map.get("topologies")

    assert id == saved["topology_id"]

    assert other |> bearer() |> get("/api/v1/topologies") |> json_response(200) == %{
             "topologies" => []
           }

    assert other
           |> bearer()
           |> get("/api/v1/topologies/#{id}")
           |> json_response(404)
           |> Map.get("error") ==
             "topology_not_found"
  end

  test "saving a new version requires the version the editor started from", %{owner: owner} do
    saved = create(owner, "Versioned")
    path = "/api/v1/topologies/#{saved["topology_id"]}"
    design = put_in(@design, ["nodes", Access.at(0), "properties", "state"], "exited")
    body = %{"name" => "Versioned", "design" => design, "layout" => @layout, "base_version" => 1}

    updated = owner |> bearer() |> put(path, body) |> json_response(200) |> Map.fetch!("topology")
    assert updated["version"] == 2
    assert updated["design"] == design
    refute updated["design_sha256"] == saved["design_sha256"]

    assert owner |> bearer() |> put(path, body) |> json_response(409) |> Map.get("error") ==
             "topology_version_conflict"
  end

  test "invalid designs, layouts and names are refused before saving", %{owner: owner} do
    invalid = [
      %{"name" => "", "design" => @design, "layout" => @layout},
      %{"name" => String.duplicate("n", 121), "design" => @design, "layout" => @layout},
      %{"name" => "X", "design" => %{"nodes" => []}, "layout" => %{}},
      %{"name" => "X", "design" => Map.put(@design, "apply", true), "layout" => @layout},
      %{"name" => "X", "design" => duplicate_node(), "layout" => @layout},
      %{"name" => "X", "design" => unknown_edge(), "layout" => @layout},
      %{"name" => "X", "design" => self_loop(), "layout" => @layout},
      %{"name" => "X", "design" => bad_relation(), "layout" => @layout},
      %{"name" => "X", "design" => bad_node_id(), "layout" => @layout},
      %{"name" => "X", "design" => nested_property(), "layout" => @layout},
      %{"name" => "X", "design" => @design, "layout" => Map.delete(@layout, "endpoint:phoenix")},
      %{
        "name" => "X",
        "design" => @design,
        "layout" => Map.put(@layout, "ghost:node", %{"x" => 1, "y" => 1})
      },
      %{
        "name" => "X",
        "design" => @design,
        "layout" => put_in(@layout, ["endpoint:phoenix", "x"], 1.5)
      },
      %{
        "name" => "X",
        "design" => @design,
        "layout" => put_in(@layout, ["endpoint:phoenix", "x"], 100_001)
      }
    ]

    for body <- invalid do
      assert owner
             |> bearer()
             |> post("/api/v1/topologies", body)
             |> json_response(422)
             |> Map.get("error") ==
               "invalid_topology",
             "accepted #{inspect(body, limit: 4)}"
    end

    assert owner |> bearer() |> get("/api/v1/topologies") |> json_response(200) == %{
             "topologies" => []
           }
  end

  test "credentials inside a design are refused with their own code", %{owner: owner} do
    for properties <- [
          %{"admin_password" => "x"},
          %{"note" => "token=abcdef123"},
          %{"api_key" => "x"}
        ] do
      design = put_in(@design, ["nodes", Access.at(0), "properties"], properties)

      assert owner
             |> bearer()
             |> post("/api/v1/topologies", %{
               "name" => "X",
               "design" => design,
               "layout" => @layout
             })
             |> json_response(422)
             |> Map.get("error") == "private_topology_content"
    end
  end

  test "another owner cannot change, archive or check a topology", %{owner: owner} do
    other = AuthTestSupport.authenticated_identity!()
    saved = create(owner, "Mine")
    path = "/api/v1/topologies/#{saved["topology_id"]}"
    body = %{"name" => "Stolen", "design" => @design, "layout" => @layout, "base_version" => 1}

    assert other |> bearer() |> put(path, body) |> json_response(404)
    assert other |> bearer() |> delete(path) |> json_response(404)
    assert other |> bearer() |> post(path <> "/drift", %{"version" => 1}) |> json_response(404)
    refute_received {:engineering_request, _, _, _}
    assert get_topology(owner, saved["topology_id"])["name"] == "Mine"
  end

  test "archiving hides the topology", %{owner: owner} do
    saved = create(owner, "Retired")
    path = "/api/v1/topologies/#{saved["topology_id"]}"

    assert owner |> bearer() |> delete(path) |> json_response(200) == %{
             "archived" => true,
             "topology_id" => saved["topology_id"]
           }

    assert owner |> bearer() |> get(path) |> json_response(404)

    assert owner |> bearer() |> get("/api/v1/topologies") |> json_response(200) == %{
             "topologies" => []
           }
  end

  test "drift sends exactly the saved version and never a client-chosen owner", %{owner: owner} do
    saved = create(owner, "Checked")

    report =
      owner
      |> bearer()
      |> post("/api/v1/topologies/#{saved["topology_id"]}/drift", %{"version" => 1})
      |> json_response(200)

    topology_id = saved["topology_id"]

    assert_receive {:engineering_request, @drift_path,
                    %{"topology_id" => ^topology_id, "version" => 1, "topology" => @design} = body,
                    ["engineering-test-internal"]}

    assert map_size(body) == 3
    assert report["topology_id"] == topology_id and report["topology_version"] == 1
    assert report["state_kind"] == "simulated" and report["execution_enabled"] == false
  end

  test "a save racing a newer version cannot overwrite it", %{owner: owner} do
    saved = create(owner, "Raced")
    id = saved["topology_id"]

    input = %{
      "name" => "Late writer",
      "design" => @design,
      "design_sha256" => saved["design_sha256"],
      "layout" => @layout
    }

    newer = Map.put(input, "name", "First writer")
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    owner_id = owner.user["user_id"]

    assert {:ok, %{"version" => 2}} =
             ItsmBackend.Topologies.SurrealStore.update_version(owner_id, id, 1, newer, now)

    # The late writer still believes version 1 is current; the store refuses it.
    assert {:error, :version_conflict} =
             ItsmBackend.Topologies.SurrealStore.update_version(owner_id, id, 1, input, now)

    assert get_topology(owner, id)["name"] == "First writer"
  end

  test "drift of an outdated version is refused before reaching the AI service", %{owner: owner} do
    saved = create(owner, "Moving")
    path = "/api/v1/topologies/#{saved["topology_id"]}"
    body = %{"name" => "Moving", "design" => @design, "layout" => @layout, "base_version" => 1}
    owner |> bearer() |> put(path, body) |> json_response(200)

    assert owner
           |> bearer()
           |> post(path <> "/drift", %{"version" => 1})
           |> json_response(409)
           |> Map.get("error") ==
             "topology_version_conflict"

    refute_received {:engineering_request, _, _, _}
  end

  test "a drift report that does not match the request is never forwarded", %{
    owner: owner,
    responses: responses
  } do
    saved = create(owner, "Guarded")
    path = "/api/v1/topologies/#{saved["topology_id"]}/drift"

    for report <- [
          Map.put(drift_report(saved["topology_id"], 1), "execution_enabled", true),
          Map.put(drift_report(saved["topology_id"], 1), "apply_to_live", true),
          Map.put(drift_report(saved["topology_id"], 1), "state_kind", "observed"),
          Map.put(drift_report(saved["topology_id"], 1), "topology_version", 2),
          Map.put(drift_report(String.duplicate("f", 32), 1), "schema", "topology-drift.v1"),
          Map.put(drift_report(saved["topology_id"], 1), "schema", "other.v1"),
          Map.put(drift_report(saved["topology_id"], 1), "commands", ["reboot"]),
          Map.delete(drift_report(saved["topology_id"], 1), "nodes")
        ] do
      Agent.update(responses, &Map.put(&1, @drift_path, {200, report}))

      assert owner
             |> bearer()
             |> post(path, %{"version" => 1})
             |> json_response(503)
             |> Map.get("error") ==
               "engineering_unavailable"
    end
  end

  test "AI refusals keep only their public code", %{owner: owner, responses: responses} do
    saved = create(owner, "Refused")
    path = "/api/v1/topologies/#{saved["topology_id"]}/drift"
    Agent.update(responses, &Map.put(&1, @drift_path, {422, %{"detail" => "invalid_topology"}}))

    assert owner
           |> bearer()
           |> post(path, %{"version" => 1})
           |> json_response(422)
           |> Map.get("error") ==
             "invalid_topology"

    Agent.update(
      responses,
      &Map.put(&1, @drift_path, {422, %{"detail" => "secret upstream text"}})
    )

    response = owner |> bearer() |> post(path, %{"version" => 1}) |> json_response(422)
    assert response["error"] == "invalid_engineering_request"
    refute inspect(response) =~ "secret upstream"

    Agent.update(responses, &Map.put(&1, @drift_path, {500, %{"detail" => "boom"}}))

    assert owner
           |> bearer()
           |> post(path, %{"version" => 1})
           |> json_response(503)
           |> Map.get("error") ==
             "engineering_unavailable"
  end

  test "netlist inspection forwards only the text", %{owner: owner} do
    report =
      owner
      |> bearer()
      |> post("/api/v1/engineering/netlist", %{"netlist" => "(export (version \"E\"))"})
      |> json_response(200)

    assert_receive {:engineering_request, @netlist_path,
                    %{"netlist" => "(export (version \"E\"))"} = body,
                    ["engineering-test-internal"]}

    assert map_size(body) == 1
    assert report["actuation"] == "none"
  end

  test "netlists are bounded and typed before forwarding", %{owner: owner} do
    for body <- [
          %{"netlist" => ""},
          %{"netlist" => 3},
          %{"netlist" => String.duplicate("x", 2_000_001)}
        ] do
      assert owner |> bearer() |> post("/api/v1/engineering/netlist", body) |> json_response(422)
    end

    refute_received {:engineering_request, _, _, _}
  end

  test "a netlist report that claims actuation is never forwarded", %{
    owner: owner,
    responses: responses
  } do
    Agent.update(
      responses,
      &Map.put(&1, @netlist_path, {200, Map.put(netlist_report(), "actuation", "flash")})
    )

    assert owner
           |> bearer()
           |> post("/api/v1/engineering/netlist", %{"netlist" => "(export)"})
           |> json_response(503)
           |> Map.get("error") == "engineering_unavailable"
  end

  test "cookie sessions need CSRF for every change and check; anonymous requests are refused", %{
    owner: owner
  } do
    saved = create(owner, "Guarded")

    cookie =
      build_conn() |> put_req_cookie(RuntimeConfig.auth!().cookie_name, owner.auth.raw_token)

    body = %{"name" => "X", "design" => @design, "layout" => @layout}

    for {method, path, payload} <- [
          {:post, "/api/v1/topologies", body},
          {:put, "/api/v1/topologies/#{saved["topology_id"]}", Map.put(body, "base_version", 1)},
          {:delete, "/api/v1/topologies/#{saved["topology_id"]}", %{}},
          {:post, "/api/v1/topologies/#{saved["topology_id"]}/drift", %{"version" => 1}},
          {:post, "/api/v1/engineering/netlist", %{"netlist" => "(export)"}}
        ] do
      assert cookie |> dispatch(@endpoint, method, path, payload) |> json_response(403) == %{
               "error" => "csrf_failed"
             }
    end

    refute_received {:engineering_request, _, _, _}
    assert build_conn() |> get("/api/v1/topologies") |> json_response(401)

    assert build_conn()
           |> post("/api/v1/engineering/netlist", %{"netlist" => "(export)"})
           |> json_response(401)
  end

  test "routes declare their exact arguments" do
    contracts = ApiContract.audit!()
    find = fn method, path -> Enum.find(contracts, &(&1.method == method and &1.path == path)) end

    assert find.("POST", "/api/v1/topologies").required_body_params == [
             "name",
             "design",
             "layout"
           ]

    assert find.("PUT", "/api/v1/topologies/:id").required_body_params ==
             ["name", "design", "layout", "base_version"]

    assert find.("POST", "/api/v1/topologies/:id/drift").required_body_params == ["version"]
    assert find.("POST", "/api/v1/engineering/netlist").required_body_params == ["netlist"]
  end

  defp create(owner, name) do
    owner
    |> bearer()
    |> post("/api/v1/topologies", %{"name" => name, "design" => @design, "layout" => @layout})
    |> json_response(201)
    |> Map.fetch!("topology")
  end

  defp get_topology(owner, id),
    do:
      owner
      |> bearer()
      |> get("/api/v1/topologies/#{id}")
      |> json_response(200)
      |> Map.fetch!("topology")

  defp duplicate_node, do: Map.update!(@design, "nodes", &(&1 ++ [hd(&1)]))

  defp unknown_edge,
    do:
      Map.update!(
        @design,
        "edges",
        &(&1 ++
            [%{"from" => "endpoint:phoenix", "to" => "ghost:node", "relation" => "depends_on"}])
      )

  defp self_loop,
    do:
      Map.put(@design, "edges", [
        %{"from" => "endpoint:phoenix", "to" => "endpoint:phoenix", "relation" => "depends_on"}
      ])

  defp bad_relation, do: put_in(@design, ["edges", Access.at(0), "relation"], "executes")
  defp bad_node_id, do: put_in(@design, ["nodes", Access.at(0), "id"], "../outside")

  defp nested_property,
    do: put_in(@design, ["nodes", Access.at(0), "properties"], %{"nested" => %{"a" => 1}})

  defp drift_report(topology_id, version),
    do: ItsmBackendWeb.EngineeringProbePlug.drift_report(topology_id, version)

  defp netlist_report do
    %{
      "schema" => "pcb-netlist-inspection.v1",
      "state_kind" => "desired",
      "actuation" => "none",
      "format" => "kicad",
      "tool" => "Eeschema 7.0.10",
      "sha256" => String.duplicate("b", 64),
      "summary" => %{
        "components" => 0,
        "nets" => 0,
        "connections" => 0,
        "errors" => 0,
        "warnings" => 0
      },
      "components" => [],
      "nets" => [],
      "findings" => [],
      "findings_truncated" => false
    }
  end

  defp bearer(identity), do: AuthTestSupport.bearer_conn(build_conn(), identity.auth.raw_token)
end
