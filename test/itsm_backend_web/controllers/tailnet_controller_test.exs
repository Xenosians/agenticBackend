defmodule ItsmBackendWeb.TailnetControllerTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.AIClient.Mock
  alias ItsmBackendWeb.AuthTestSupport

  @overview %{
    "ok" => true,
    "status" => "success",
    "provider" => "tailscale",
    "observed_at" => "2026-11-16T05:00:00+00:00",
    "data" => %{
      "schema" => "tailnet-overview.v1",
      "devices" => %{
        "count" => 1,
        "truncated" => false,
        "summary" => %{"online" => 1, "offline" => 0, "with_issues" => 0},
        "devices" => [%{"name" => "hummingbird", "issues" => []}]
      },
      "dns" => nil,
      "dns_error" => %{
        "reason" => "provider_error",
        "message" => "Tailscale refused the read (HTTP 403)."
      }
    }
  }

  defmodule Client do
    @moduledoc false
    def tailnet_overview, do: Process.get(:tailnet_answer)

    def run(_, _), do: {:error, :unsupported_request}
    def execute_job(_, _, _, _), do: {:error, :unsupported_request}
    def approve(_), do: {:error, :unsupported_request}
    def reject(_), do: {:error, :unsupported_request}
    def health, do: {:ok, %{status: "ok"}}
    def ready, do: {:ok, %{status: "ready"}}
  end

  setup do
    previous = Application.get_env(:itsm_backend, :ai_client)
    Application.put_env(:itsm_backend, :ai_client, Client)
    on_exit(fn -> Application.put_env(:itsm_backend, :ai_client, previous) end)
    %{owner: AuthTestSupport.authenticated_identity!()}
  end

  test "the tailnet overview requires a signed-in account", %{conn: conn} do
    Process.put(:tailnet_answer, {:ok, @overview})
    assert conn |> get("/api/v1/tailnet/overview") |> json_response(401)
  end

  test "the signed-in owner gets the AI's overview as it was read", %{owner: owner} do
    Process.put(:tailnet_answer, {:ok, @overview})

    assert owner |> conn_for() |> get("/api/v1/tailnet/overview") |> json_response(200) ==
             @overview
  end

  test "an AI without the tailnet read is unavailable, not empty", %{owner: owner} do
    Application.put_env(:itsm_backend, :ai_client, Mock)

    assert owner |> conn_for() |> get("/api/v1/tailnet/overview") |> json_response(503) ==
             %{"error" => "tailnet_unavailable"}
  end

  test "an unconfigured tailnet is named", %{owner: owner} do
    Process.put(
      :tailnet_answer,
      {:error, {:ai_service_error, 503, %{"error" => "tailnet_not_configured"}}}
    )

    assert owner |> conn_for() |> get("/api/v1/tailnet/overview") |> json_response(503) ==
             %{"error" => "tailnet_not_configured"}
  end

  test "a failed read keeps its cause and fixed message", %{owner: owner} do
    Process.put(
      :tailnet_answer,
      {:error,
       {:ai_service_error, 502,
        %{
          "error" => "tailnet_read_failed",
          "reason" => "provider_unreachable",
          "message" =>
            "The Tailscale network could not be reached, or it closed the connection before answering."
        }}}
    )

    assert owner |> conn_for() |> get("/api/v1/tailnet/overview") |> json_response(503) == %{
             "error" => "tailnet_read_failed",
             "reason" => "provider_unreachable",
             "message" =>
               "The Tailscale network could not be reached, or it closed the connection before answering."
           }
  end

  test "an unexpected cause is not passed to the browser", %{owner: owner} do
    Process.put(
      :tailnet_answer,
      {:error,
       {:ai_service_error, 502,
        %{"error" => "tailnet_read_failed", "reason" => "Bad <b>", "message" => "x"}}}
    )

    assert owner |> conn_for() |> get("/api/v1/tailnet/overview") |> json_response(503) ==
             %{"error" => "tailnet_read_failed"}

    Process.put(:tailnet_answer, {:error, {:request_failed, :timeout}})

    assert owner |> conn_for() |> get("/api/v1/tailnet/overview") |> json_response(503) ==
             %{"error" => "tailnet_unavailable"}
  end

  defp conn_for(identity),
    do: build_conn() |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
end
