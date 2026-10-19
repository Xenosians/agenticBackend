defmodule ItsmBackendWeb.AuthStorageFailureTest do
  use ItsmBackendWeb.ConnCase,
    async: false

  alias ItsmBackend.Auth
  alias ItsmBackendWeb.AuthTestSupport

  test "a storage failure while checking the session is retryable, not a sign-out",
       %{conn: conn} do
    identity = AuthTestSupport.authenticated_identity!()
    conn = AuthTestSupport.bearer_conn(conn, identity.auth.raw_token)

    original = Application.fetch_env!(:itsm_backend, :surrealdb)
    # Nothing listens on port 9: the storage request fails at connect time.
    Application.put_env(
      :itsm_backend,
      :surrealdb,
      Keyword.put(original, :url, "http://127.0.0.1:9")
    )

    on_exit(fn -> Application.put_env(:itsm_backend, :surrealdb, original) end)

    conn = get(conn, ~p"/api/v1/chats")

    assert json_response(conn, 503) == %{"error" => "storage_unavailable"}
    assert get_resp_header(conn, "retry-after") == ["2"]
  end

  test "an unexpected storage answer is retryable, not a sign-out", %{conn: conn} do
    identity = AuthTestSupport.authenticated_identity!()
    ItsmBackendWeb.StorageFaultProxy.install!(:rpc_error, ~r/FROM auth_session/)

    conn =
      conn
      |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
      |> get(~p"/api/v1/chats")

    assert_received {:storage_fault, :rpc_error}
    assert json_response(conn, 503) == %{"error" => "storage_unavailable"}
  end

  test "a revoked session is a 401" do
    identity = AuthTestSupport.authenticated_identity!()

    assert {:ok, _} =
             Auth.revoke_session(identity.user["user_id"], identity.auth.session["session_id"])

    conn =
      build_conn()
      |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
      |> get(~p"/api/v1/chats")

    assert json_response(conn, 401) == %{"error" => "authentication_required"}
  end

  test "a missing session is still a 401" do
    conn = get(build_conn(), ~p"/api/v1/chats")

    assert json_response(conn, 401) == %{"error" => "authentication_required"}
  end
end
