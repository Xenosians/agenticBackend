defmodule ItsmBackendWeb.LogoutTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.Auth
  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.AuthTestSupport
  alias ItsmBackendWeb.StorageFaultProxy

  @revoke ~r/SET revoked_at/

  defp logout(raw_token) do
    build_conn()
    |> AuthTestSupport.bearer_conn(raw_token)
    |> post(~p"/api/v1/auth/logout", %{})
  end

  defp cookie_name, do: RuntimeConfig.auth!().cookie_name

  test "logout ends the session and clears the cookie" do
    id = AuthTestSupport.authenticated_identity!()

    conn = logout(id.auth.raw_token)

    assert json_response(conn, 200) == %{"status" => "logged_out"}
    assert conn.resp_cookies[cookie_name()][:max_age] == 0
    assert {:error, :invalid_session} = Auth.authenticate_session(id.auth.raw_token)
  end

  test "a failed revocation is reported, and the session stays usable for a retry" do
    id = AuthTestSupport.authenticated_identity!()
    restore = StorageFaultProxy.install!(:http_500, @revoke)

    conn = logout(id.auth.raw_token)

    assert_received {:storage_fault, :http_500}
    body = json_response(conn, 503)
    assert body["error"] == "logout_unconfirmed"
    assert body["retryable"] == true
    assert get_resp_header(conn, "retry-after") == ["2"]
    refute Map.has_key?(conn.resp_cookies, cookie_name())

    restore.()
    assert {:ok, _user, _session} = Auth.authenticate_session(id.auth.raw_token)
    assert json_response(logout(id.auth.raw_token), 200) == %{"status" => "logged_out"}
    assert {:error, :invalid_session} = Auth.authenticate_session(id.auth.raw_token)
  end

  test "a revoke that silently matched nothing is checked, not trusted" do
    id = AuthTestSupport.authenticated_identity!()
    restore = StorageFaultProxy.install!(:empty_result, @revoke)

    conn = logout(id.auth.raw_token)

    assert_received {:storage_fault, :empty_result}
    assert json_response(conn, 503)["error"] == "logout_unconfirmed"
    restore.()
    assert {:ok, _user, _session} = Auth.authenticate_session(id.auth.raw_token)
  end

  test "a lost answer is unconfirmed even when the revoke ran; the retry sees no session" do
    id = AuthTestSupport.authenticated_identity!()
    restore = StorageFaultProxy.install!(:lost_response, @revoke)

    conn = logout(id.auth.raw_token)

    assert_received {:storage_fault, :lost_response}
    assert json_response(conn, 503)["error"] == "logout_unconfirmed"
    restore.()
    assert {:error, :invalid_session} = Auth.authenticate_session(id.auth.raw_token)
    # The browser's retry learns that no valid session is left.
    assert json_response(logout(id.auth.raw_token), 401) == %{
             "error" => "authentication_required"
           }
  end
end
