defmodule ItsmBackendWeb.AgentControllerTest do
  use ItsmBackendWeb.ConnCase, async: true

  test "returns success for an account status request", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/agent/run", %{
        "user_id" => "jdoe",
        "message" => "Is jdoe locked?"
      })

    assert %{
             "status" => "success",
             "request_id" => "req-mock-001",
             "routes" => ["account-specialist"],
             "result" => %{
               "user_id" => "jdoe",
               "locked" => false
             }
           } = json_response(conn, 200)
  end
end
