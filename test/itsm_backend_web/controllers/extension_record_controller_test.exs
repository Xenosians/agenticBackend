defmodule ItsmBackendWeb.ExtensionRecordControllerTest do
  @moduledoc """
  Owner-scoped Lua extension lifecycle over HTTP (Stage 4.2).

  Registration, review, activation, revocation and the durable on/off
  switch are authenticated, CSRF-bound mutations; another owner's record
  is a 404 and a forbidden transition is a 409, never a second event.
  """
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackendWeb.{ApiContract, AuthTestSupport}

  @manifest %{
    "schema" => "extension-manifest.v1",
    "id" => "lua-row-transform",
    "version" => "1.0.0",
    "contract_version" => 1,
    "input_schema" => "urn:agentic-itsm:contracts:v1:extensions:invocation",
    "output_schema" => "urn:agentic-itsm:contracts:v1:extensions:result",
    "limits" => %{
      "max_source_bytes" => 20000,
      "max_input_bytes" => 2_000_000,
      "max_rows" => 10000,
      "max_output_bytes" => 2_000_000,
      "max_instructions" => 20_000_000,
      "max_memory_bytes" => 67_108_864,
      "max_cpu_seconds" => 10,
      "max_address_space_bytes" => 805_306_368,
      "max_wall_seconds" => 20
    }
  }

  setup do
    %{owner: AuthTestSupport.authenticated_identity!()}
  end

  defp body(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "lua_plugin",
        "manifest" => @manifest,
        "source_type" => "lua_source",
        "source_sha256" =>
          :crypto.hash(:sha256, "return function(row) return row end")
          |> Base.encode16(case: :lower)
      },
      overrides
    )
  end

  defp bearer(identity), do: AuthTestSupport.bearer_conn(build_conn(), identity.auth.raw_token)

  defp create(owner, overrides \\ %{}) do
    owner |> bearer() |> post("/api/v1/extensions/records", body(overrides))
  end

  test "register, review, activate and toggle over HTTP", %{owner: owner} do
    assert [record] =
             owner
             |> create()
             |> json_response(201)
             |> Map.fetch!("extension")
             |> List.wrap()

    assert record["status"] == "pending"
    assert record["record_id"] =~ ~r/\A[0-9a-f]{32}\z/

    id = record["record_id"]

    assert owner |> bearer() |> get("/api/v1/extensions/records") |> json_response(200) == %{
             "extensions" => [record]
           }

    assert owner |> bearer() |> get("/api/v1/extensions/records/#{id}") |> json_response(200) ==
             %{"extension" => record}

    for {path, expected_status} <- [
          {"/review", "reviewed"},
          {"/activate", "active"},
          {"/disable", "disabled"},
          {"/enable", "active"}
        ] do
      response =
        owner
        |> bearer()
        |> post("/api/v1/extensions/records/#{id}#{path}", %{})
        |> json_response(200)

      assert response["extension"]["status"] == expected_status
    end

    events =
      owner
      |> bearer()
      |> get("/api/v1/extensions/records/#{id}/events")
      |> json_response(200)
      |> Map.fetch!("events")

    assert Enum.map(events, & &1["action"]) ==
             ["register", "review", "activate", "disable", "enable"]
  end

  test "a forbidden transition is a conflict that names the current status", %{owner: owner} do
    id =
      owner
      |> create()
      |> json_response(201)
      |> Map.fetch!("extension")
      |> Map.fetch!("record_id")

    response =
      owner
      |> bearer()
      |> post("/api/v1/extensions/records/#{id}/activate", %{})
      |> json_response(409)

    assert response["error"] == "extension_transition_not_allowed"
    assert response["current_status"] == "pending"
  end

  test "invalid manifests and digests are 422 and create nothing", %{owner: owner} do
    bad = body(%{"manifest" => Map.put(@manifest, "version", "1.0")})

    response =
      owner |> bearer() |> post("/api/v1/extensions/records", bad) |> json_response(422)

    assert response["error"] == "extension_invalid"
    assert response["message"] == "Check the kind, manifest, source type and source digest."
    assert response["retryable"] == false

    assert owner |> bearer() |> get("/api/v1/extensions/records") |> json_response(200) == %{
             "extensions" => []
           }
  end

  test "another owner cannot inspect or move the record", %{owner: owner} do
    other = AuthTestSupport.authenticated_identity!()

    id =
      owner
      |> create()
      |> json_response(201)
      |> Map.fetch!("extension")
      |> Map.fetch!("record_id")

    assert other |> bearer() |> get("/api/v1/extensions/records") |> json_response(200) == %{
             "extensions" => []
           }

    for path <- ["", "/events"] do
      assert other
             |> bearer()
             |> get("/api/v1/extensions/records/#{id}#{path}")
             |> json_response(404)
             |> Map.get("error") == "extension_not_found"
    end

    for action <- ["review", "activate", "revoke", "disable", "enable"] do
      assert other
             |> bearer()
             |> post("/api/v1/extensions/records/#{id}/#{action}", %{})
             |> json_response(404)
             |> Map.get("error") == "extension_not_found"
    end

    assert owner |> bearer() |> get("/api/v1/extensions/records/#{id}") |> json_response(200)
  end

  test "anonymous requests are refused and the existing catalog proxy is untouched", %{
    owner: owner
  } do
    assert build_conn() |> get("/api/v1/extensions/records") |> json_response(401)

    assert build_conn()
           |> post("/api/v1/extensions/records", body())
           |> json_response(401)

    # The read-only catalog route keeps its own controller and shape.
    assert build_conn() |> get("/api/v1/extensions") |> json_response(401)
    assert owner |> bearer() |> get("/api/v1/extensions/records") |> json_response(200)
  end

  test "cookie sessions need CSRF for every mutation", %{owner: owner} do
    id =
      owner
      |> create()
      |> json_response(201)
      |> Map.fetch!("extension")
      |> Map.fetch!("record_id")

    cookie =
      build_conn()
      |> put_req_cookie(ItsmBackend.RuntimeConfig.auth!().cookie_name, owner.auth.raw_token)

    assert cookie |> post("/api/v1/extensions/records", body()) |> json_response(403) ==
             %{"error" => "csrf_failed"}

    assert cookie
           |> post("/api/v1/extensions/records/#{id}/review", %{})
           |> json_response(403) == %{"error" => "csrf_failed"}

    # Reads never need CSRF.
    assert cookie |> get("/api/v1/extensions/records") |> json_response(200)
  end

  test "routes declare their exact arguments" do
    contracts = ApiContract.audit!()
    find = fn method, path -> Enum.find(contracts, &(&1.method == method and &1.path == path)) end

    assert find.("GET", "/api/v1/extensions/records").required_body_params == []

    assert find.("POST", "/api/v1/extensions/records").required_body_params == [
             "kind",
             "manifest",
             "source_type",
             "source_sha256"
           ]

    assert find.("POST", "/api/v1/extensions/records/:id/review").required_path_params == ["id"]
    assert find.("GET", "/api/v1/extensions/records/:id/events").required_path_params == ["id"]
  end
end
