defmodule ItsmBackendWeb.AccountPreferencesTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.{Auth, Surreal}
  alias ItsmBackend.Auth.{Preferences, SurrealStore}
  alias ItsmBackendWeb.{AuthTestSupport, StorageFaultProxy}

  @preference_write ~r/SET notification_preferences.task_completed/
  @other_revoke ~r/LET \$revoked = UPDATE auth_session/

  test "preferences default on, persist explicitly, and never update another owner" do
    owner = AuthTestSupport.authenticated_identity!()
    other = AuthTestSupport.authenticated_identity!()

    assert json_response(get(authed(owner), "/api/v1/auth/preferences"), 200) ==
             %{"preferences" => %{"task_completed" => true}}

    assert json_response(
             put(authed(owner), "/api/v1/auth/preferences", %{"task_completed" => false}),
             200
           ) ==
             %{"preferences" => %{"task_completed" => false}}

    assert {:ok, %{"task_completed" => false}} = Preferences.get(owner.user["user_id"])
    assert {:ok, %{"task_completed" => true}} = Preferences.get(other.user["user_id"])

    assert json_response(
             put(authed(owner), "/api/v1/auth/preferences", %{"task_completed" => true}),
             200
           ) ==
             %{"preferences" => %{"task_completed" => true}}
  end

  test "preference reads and writes authenticate, writes require CSRF and strict booleans" do
    owner = AuthTestSupport.authenticated_identity!()
    assert json_response(get(build_conn(), "/api/v1/auth/preferences"), 401)
    assert json_response(get(authed(owner), "/api/v1/auth/preferences?unexpected=true"), 422)

    assert json_response(
             put(build_conn(), "/api/v1/auth/preferences", %{"task_completed" => false}),
             401
           )

    cookie = cookie_conn(owner)

    assert json_response(
             put(cookie, "/api/v1/auth/preferences", %{"task_completed" => false}),
             403
           )["error"] == "csrf_failed"

    assert json_response(
             put(
               put_req_header(cookie, "x-csrf-token", owner.auth.csrf_token),
               "/api/v1/auth/preferences",
               %{"task_completed" => false}
             ),
             200
           )["preferences"]["task_completed"] == false

    for body <- [
          %{},
          %{"task_completed" => "false"},
          %{"task_completed" => nil},
          %{"task_completed" => 0},
          %{"task_completed" => true, "user_id" => "another"}
        ] do
      assert json_response(put(authed(owner), "/api/v1/auth/preferences", body), 422)
    end

    assert json_response(
             put(authed(owner), "/api/v1/auth/preferences?task_completed=false", %{
               "task_completed" => true
             }),
             422
           )
  end

  test "malformed stored preferences are unknown, not defaulted or overwritten" do
    owner = AuthTestSupport.authenticated_identity!()

    for bad <- [%{"task_completed" => "false"}, nil, "disabled"] do
      assert {:ok, _} =
               Surreal.query(
                 "UPDATE ONLY type::record('app_user', $id) SET notification_preferences = $bad;",
                 %{"id" => owner.user["user_id"], "bad" => bad}
               )

      assert json_response(get(authed(owner), "/api/v1/auth/preferences"), 503)["error"] ==
               "preferences_unavailable"

      assert json_response(
               put(authed(owner), "/api/v1/auth/preferences", %{"task_completed" => false}),
               503
             )["error"] == "preferences_save_unconfirmed"
    end
  end

  test "failed preference writes cannot claim saved, but a lost receipt is read back" do
    owner = AuthTestSupport.authenticated_identity!()
    restore = StorageFaultProxy.install!(:http_500, @preference_write)

    assert json_response(
             put(authed(owner), "/api/v1/auth/preferences", %{"task_completed" => false}),
             503
           )["error"] == "preferences_save_unconfirmed"

    assert_received {:storage_fault, :http_500}
    restore.()
    assert {:ok, %{"task_completed" => true}} = Preferences.get(owner.user["user_id"])

    restore = StorageFaultProxy.install!(:lost_response, @preference_write)

    assert json_response(
             put(authed(owner), "/api/v1/auth/preferences", %{"task_completed" => false}),
             200
           )["preferences"]["task_completed"] == false

    assert_received {:storage_fault, :lost_response}
    restore.()
    assert {:ok, %{"task_completed" => false}} = Preferences.get(owner.user["user_id"])
  end

  test "preference storage read failures return an unavailable response" do
    owner = AuthTestSupport.authenticated_identity!()
    # Authentication also reads app_user, so target only preference retrieval via the domain here.
    restore = StorageFaultProxy.install!(:rpc_error, ~r/SELECT \* FROM ONLY/)
    assert {:error, :preferences_unavailable} = Preferences.get(owner.user["user_id"])
    assert_received {:storage_fault, :rpc_error}
    restore.()
  end

  test "end other sessions keeps exact caller and other owner, excludes expired and already ended" do
    owner = AuthTestSupport.authenticated_identity!()
    other = AuthTestSupport.authenticated_identity!()
    first = another_session(owner)
    second = another_session(owner)

    expired =
      another_session(owner, %{
        "expires_at" => DateTime.add(DateTime.utc_now(), -60) |> DateTime.to_iso8601()
      })

    ended = another_session(owner, %{"revoked_at" => DateTime.utc_now() |> DateTime.to_iso8601()})

    response = post(authed(owner), "/api/v1/auth/sessions/revoke-others", %{})
    assert json_response(response, 200) == %{"status" => "revoked", "revoked_count" => 2}
    assert {:ok, _, _} = Auth.authenticate_session(owner.auth.raw_token)
    assert {:ok, _, _} = Auth.authenticate_session(other.auth.raw_token)

    for raw <- [first, second, expired, ended],
        do: assert({:error, :invalid_session} = Auth.authenticate_session(raw))

    assert json_response(post(authed(owner), "/api/v1/auth/sessions/revoke-others", %{}), 200) ==
             %{"status" => "revoked", "revoked_count" => 0}
  end

  test "end other sessions requires authentication, CSRF and an empty input" do
    owner = AuthTestSupport.authenticated_identity!()
    assert json_response(post(build_conn(), "/api/v1/auth/sessions/revoke-others", %{}), 401)

    assert json_response(
             post(cookie_conn(owner), "/api/v1/auth/sessions/revoke-others", %{}),
             403
           )["error"] == "csrf_failed"

    assert json_response(
             post(authed(owner), "/api/v1/auth/sessions/revoke-others", %{"user_id" => "another"}),
             422
           )

    assert json_response(
             post(authed(owner), "/api/v1/auth/sessions/revoke-others?unexpected=true", %{}),
             422
           )

    assert json_response(
             post(
               put_req_header(cookie_conn(owner), "x-csrf-token", owner.auth.csrf_token),
               "/api/v1/auth/sessions/revoke-others",
               %{}
             ),
             200
           )["revoked_count"] == 0

    assert {:ok, _, _} = Auth.authenticate_session(owner.auth.raw_token)
  end

  test "a stale caller session cannot authorize ending other sessions" do
    owner = AuthTestSupport.authenticated_identity!()
    other_raw = another_session(owner)
    assert :ok = Auth.end_session(owner.user["user_id"], owner.auth.session["session_id"])

    assert {:error, :session_revoke_unconfirmed} =
             Auth.revoke_other_sessions(owner.user["user_id"], owner.auth.session["session_id"])

    assert {:ok, _, _} = Auth.authenticate_session(other_raw)
  end

  test "lost other-session revoke receipt is unknown even if the sessions were ended" do
    owner = AuthTestSupport.authenticated_identity!()
    other_raw = another_session(owner)
    restore = StorageFaultProxy.install!(:lost_response, @other_revoke)

    assert json_response(post(authed(owner), "/api/v1/auth/sessions/revoke-others", %{}), 503)[
             "error"
           ] == "session_revoke_unconfirmed"

    assert_received {:storage_fault, :lost_response}
    restore.()
    assert {:error, :invalid_session} = Auth.authenticate_session(other_raw)
    assert {:ok, _, _} = Auth.authenticate_session(owner.auth.raw_token)
  end

  test "empty and failed revoke receipts never claim sessions ended" do
    owner = AuthTestSupport.authenticated_identity!()
    other_raw = another_session(owner)

    for fault <- [:empty_result, :http_500] do
      restore = StorageFaultProxy.install!(fault, @other_revoke)

      assert json_response(post(authed(owner), "/api/v1/auth/sessions/revoke-others", %{}), 503)[
               "error"
             ] == "session_revoke_unconfirmed"

      assert_received {:storage_fault, ^fault}
      restore.()
      assert {:ok, _, _} = Auth.authenticate_session(other_raw)
      assert {:ok, _, _} = Auth.authenticate_session(owner.auth.raw_token)
    end
  end

  defp another_session(owner, changes \\ %{}) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    record =
      owner.auth.session
      |> Map.drop(["id"])
      |> Map.merge(%{
        "session_id" => id,
        "token_hash" => :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
      })
      |> Map.merge(changes)

    assert {:ok, %{}} = SurrealStore.create_session(record)
    raw
  end

  defp authed(owner), do: build_conn() |> AuthTestSupport.bearer_conn(owner.auth.raw_token)

  defp cookie_conn(owner),
    do:
      build_conn()
      |> put_req_cookie(ItsmBackend.RuntimeConfig.auth!().cookie_name, owner.auth.raw_token)
end
