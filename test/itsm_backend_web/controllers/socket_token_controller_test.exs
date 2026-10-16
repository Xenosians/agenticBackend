defmodule ItsmBackendWeb.SocketTokenControllerTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.{Auth, RuntimeConfig}
  alias ItsmBackendWeb.{AuthTestSupport, SocketAuth}

  test "ticket issuance requires authentication and cookie CSRF" do
    path = "/api/v2/jobs/socket-token"
    assert build_conn() |> post(path, %{}) |> json_response(401)
    id = AuthTestSupport.authenticated_identity!()

    cookie_conn = fn ->
      build_conn() |> put_req_cookie(RuntimeConfig.auth!().cookie_name, id.auth.raw_token)
    end

    assert cookie_conn.() |> post(path, %{}) |> json_response(403)
    conn = cookie_conn.() |> put_req_header("x-csrf-token", id.auth.csrf_token) |> post(path, %{})
    response = json_response(conn, 200)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert Map.keys(response) |> Enum.sort() == ["expires_in", "token"]
    assert response["expires_in"] == 120
    assert {:ok, user, session_id} = SocketAuth.authenticate(response["token"])
    assert user["user_id"] == id.user["user_id"]
    assert session_id == id.auth.session["session_id"]
    refute Jason.encode!(response) =~ id.auth.raw_token
    refute Jason.encode!(response) =~ id.auth.csrf_token
  end

  test "revoked browser session cannot obtain a ticket" do
    id = AuthTestSupport.authenticated_identity!()
    assert {:ok, _} = Auth.revoke_session(id.user["user_id"], id.auth.session["session_id"])

    assert build_conn()
           |> AuthTestSupport.bearer_conn(id.auth.raw_token)
           |> post("/api/v2/jobs/socket-token", %{})
           |> json_response(401)
  end
end
