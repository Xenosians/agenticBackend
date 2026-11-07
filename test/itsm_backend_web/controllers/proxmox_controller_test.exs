defmodule ItsmBackendWeb.ProxmoxControllerTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.AIClient.Mock
  alias ItsmBackendWeb.AuthTestSupport

  defmodule NotConfiguredClient do
    @moduledoc false
    def proxmox_overview,
      do: {:error, {:ai_service_error, 503, %{"error" => "proxmox_not_configured"}}}

    def run(_, _), do: {:error, :unsupported_request}
    def execute_job(_, _, _, _), do: {:error, :unsupported_request}
    def approve(_), do: {:error, :unsupported_request}
    def reject(_), do: {:error, :unsupported_request}
    def health, do: {:ok, %{status: "ok"}}
    def ready, do: {:ok, %{status: "ready"}}
  end

  defmodule InvalidClient do
    @moduledoc false
    def proxmox_overview,
      do: {:error, {:ai_service_error, 503, %{"error" => "proxmox_configuration_invalid"}}}

    def run(_, _), do: {:error, :unsupported_request}
    def execute_job(_, _, _, _), do: {:error, :unsupported_request}
    def approve(_), do: {:error, :unsupported_request}
    def reject(_), do: {:error, :unsupported_request}
    def health, do: {:ok, %{status: "ok"}}
    def ready, do: {:ok, %{status: "ready"}}
  end

  defmodule ReadFailedClient do
    @moduledoc false
    def proxmox_overview,
      do: {:error, {:ai_service_error, 502, %{"error" => "proxmox_read_failed"}}}

    def run(_, _), do: {:error, :unsupported_request}
    def execute_job(_, _, _, _), do: {:error, :unsupported_request}
    def approve(_), do: {:error, :unsupported_request}
    def reject(_), do: {:error, :unsupported_request}
    def health, do: {:ok, %{status: "ok"}}
    def ready, do: {:ok, %{status: "ready"}}
  end

  setup do
    previous = Application.get_env(:itsm_backend, :ai_client)
    Application.put_env(:itsm_backend, :ai_client, Mock)
    on_exit(fn -> Application.put_env(:itsm_backend, :ai_client, previous) end)
    %{owner: AuthTestSupport.authenticated_identity!()}
  end

  test "dashboard requires a signed-in account", %{conn: conn} do
    assert conn |> get("/api/v1/proxmox/overview") |> json_response(401)
  end

  test "unavailable Proxmox reads stay unavailable", %{owner: owner} do
    response = owner |> conn_for() |> get("/api/v1/proxmox/overview") |> json_response(503)
    assert response == %{"error" => "proxmox_dashboard_unavailable"}
  end

  test "each named AI state is forwarded distinctly", %{owner: owner} do
    for {client, code} <- [
          {NotConfiguredClient, "proxmox_not_configured"},
          {InvalidClient, "proxmox_configuration_invalid"},
          {ReadFailedClient, "proxmox_read_failed"}
        ] do
      Application.put_env(:itsm_backend, :ai_client, client)

      response =
        owner |> conn_for() |> get("/api/v1/proxmox/overview") |> json_response(503)

      assert response == %{"error" => code}
    end
  end

  defp conn_for(identity),
    do: build_conn() |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
end
