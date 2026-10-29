defmodule ItsmBackendWeb.ExtensionControllerTest do
  use ItsmBackendWeb.ConnCase, async: false
  alias ItsmBackendWeb.AuthTestSupport
  alias ItsmBackend.RuntimeConfig

  setup do
    original = Application.get_env(:itsm_backend, :ai_service)
    original_token = Application.get_env(:itsm_backend, :internal_job_token)

    server =
      start_supervised!(
        {Bandit, plug: {ItsmBackendWeb.ExtensionProbePlug, self()}, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    Application.put_env(
      :itsm_backend,
      :ai_service,
      Keyword.put(original, :base_url, "http://127.0.0.1:#{port}")
    )

    Application.put_env(:itsm_backend, :internal_job_token, "extension-test-internal")

    on_exit(fn ->
      Application.put_env(:itsm_backend, :ai_service, original)
      Application.put_env(:itsm_backend, :internal_job_token, original_token)
    end)

    %{identity: AuthTestSupport.authenticated_identity!()}
  end

  test "proxy derives owner from the authenticated session", %{identity: identity} do
    result =
      build_conn()
      |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
      |> post("/api/v1/extensions", %{
        action: "list",
        payload: %{owner: "another-user"},
        owner: "another-user"
      })
      |> json_response(200)

    assert result["received_owner"] == identity.user["user_id"]
    assert_receive {:extension_request, request, ["extension-test-internal"]}
    assert request["owner"] == identity.user["user_id"]
  end

  test "anonymous and cookie requests without CSRF never reach the AI service", %{
    identity: identity
  } do
    assert build_conn() |> get("/api/v1/extensions") |> json_response(401)

    assert build_conn()
           |> put_req_cookie(RuntimeConfig.auth!().cookie_name, identity.auth.raw_token)
           |> post("/api/v1/extensions", %{action: "delete", payload: %{id: "anything"}})
           |> json_response(403)

    refute_received {:extension_request, _, _}
  end

  test "a Lua transform is forwarded for the session owner and its refusal stays curated", %{
    identity: identity
  } do
    owner = identity.user["user_id"]
    script = "return function(row) return row end"

    assert build_conn()
           |> put_req_cookie(RuntimeConfig.auth!().cookie_name, identity.auth.raw_token)
           |> post("/api/v1/extensions", %{
             action: "dataset_transform",
             payload: %{script: script, text: "{}"}
           })
           |> json_response(403)

    refute_received {:extension_request, _, _}

    assert build_conn()
           |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
           |> post("/api/v1/extensions", %{
             action: "dataset_transform",
             payload: %{script: script, text: "{}", owner: "another-user"}
           })
           |> json_response(200)

    assert_receive {:extension_request,
                    %{"owner" => ^owner, "action" => "dataset_transform", "payload" => payload},
                    ["extension-test-internal"]}

    assert payload["script"] == script

    refusal =
      build_conn()
      |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
      |> post("/api/v1/extensions", %{
        action: "dataset_transform",
        payload: %{script: "refuse", text: "{}"}
      })
      |> json_response(422)

    assert refusal["error"] == "extension_request_rejected"
    assert refusal["detail"]["code"] == "transform_failed"
    assert String.starts_with?(refusal["detail"]["message"], "Row 3: ")
    assert String.length(refusal["detail"]["message"]) == 300
    assert Map.keys(refusal["detail"]) |> Enum.sort() == ["code", "message"]
    refute inspect(refusal) =~ "private worker detail"
  end
end
