defmodule ItsmBackendWeb.CorsAccountTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.AuthTestSupport

  @origin "https://account-ui.example.test"
  @path "/api/v1/auth/preferences"

  setup do
    original = Application.fetch_env!(:itsm_backend, :cors)
    Application.put_env(:itsm_backend, :cors, allowed_origins: [@origin])
    on_exit(fn -> Application.put_env(:itsm_backend, :cors, original) end)
    :ok
  end

  test "the real endpoint allows credentialed preference PUT preflight from a configured origin" do
    conn = preflight(@origin, "PUT", "content-type,x-csrf-token")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
    assert "Origin" in values(conn, "vary")
    assert "PUT" in values(conn, "access-control-allow-methods")
    assert "content-type" in values(conn, "access-control-allow-headers")
    assert "x-csrf-token" in values(conn, "access-control-allow-headers")
  end

  test "an unconfigured origin never receives permission to read credentialed responses" do
    conn = preflight("https://untrusted.example.test", "PUT", "content-type,x-csrf-token")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "access-control-allow-origin") == []
    assert get_resp_header(conn, "access-control-allow-credentials") == []
  end

  test "unsupported methods and headers remain outside the preflight grant" do
    conn = preflight(@origin, "TRACE", "content-type,x-untrusted-header")

    assert response(conn, 204) == ""
    refute "TRACE" in values(conn, "access-control-allow-methods")
    refute "x-untrusted-header" in values(conn, "access-control-allow-headers")
  end

  test "chat PATCH is granted only from configured origins with allowed headers" do
    conn = preflight(@origin, "PATCH", "content-type,x-csrf-token")
    assert response(conn, 204) == ""
    assert "PATCH" in values(conn, "access-control-allow-methods")
    assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    refute "x-untrusted-header" in values(conn, "access-control-allow-headers")
    foreign = preflight("https://untrusted.example.test", "PATCH", "content-type,x-csrf-token")
    assert get_resp_header(foreign, "access-control-allow-origin") == []
  end

  test "CORS permission cannot replace authentication or cookie CSRF on the actual PUT" do
    unauthenticated =
      build_conn()
      |> put_req_header("origin", @origin)
      |> put(@path, %{"task_completed" => false})

    assert json_response(unauthenticated, 401)["error"] == "authentication_required"
    assert get_resp_header(unauthenticated, "access-control-allow-origin") == [@origin]

    owner = AuthTestSupport.authenticated_identity!()

    cookie =
      build_conn()
      |> put_req_header("origin", @origin)
      |> put_req_cookie(RuntimeConfig.auth!().cookie_name, owner.auth.raw_token)

    assert json_response(put(cookie, @path, %{"task_completed" => false}), 403)["error"] ==
             "csrf_failed"

    saved =
      cookie
      |> put_req_header("x-csrf-token", owner.auth.csrf_token)
      |> put(@path, %{"task_completed" => false})

    assert json_response(saved, 200) == %{"preferences" => %{"task_completed" => false}}
    assert get_resp_header(saved, "access-control-allow-origin") == [@origin]
    assert get_resp_header(saved, "access-control-allow-credentials") == ["true"]
  end

  defp preflight(origin, method, headers) do
    build_conn()
    |> put_req_header("origin", origin)
    |> put_req_header("access-control-request-method", method)
    |> put_req_header("access-control-request-headers", headers)
    |> options(@path)
  end

  defp values(conn, name) do
    conn
    |> get_resp_header(name)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
  end
end
