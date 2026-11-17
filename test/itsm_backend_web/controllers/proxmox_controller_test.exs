defmodule ItsmBackendWeb.ProxmoxControllerTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.AIClient.Mock
  alias ItsmBackendWeb.AuthTestSupport

  defmodule NotConfiguredClient do
    @moduledoc false
    def proxmox_overview(_owner),
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
    def proxmox_overview(_owner),
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
    def proxmox_overview(_owner),
      do: {:error, {:ai_service_error, 502, %{"error" => "proxmox_read_failed"}}}

    def run(_, _), do: {:error, :unsupported_request}
    def execute_job(_, _, _, _), do: {:error, :unsupported_request}
    def approve(_), do: {:error, :unsupported_request}
    def reject(_), do: {:error, :unsupported_request}
    def health, do: {:ok, %{status: "ok"}}
    def ready, do: {:ok, %{status: "ready"}}
  end

  defmodule TypedReadFailedClient do
    @moduledoc false
    def proxmox_overview(_owner),
      do:
        {:error,
         {:ai_service_error, 502,
          %{
            "error" => "proxmox_read_failed",
            "reason" => "provider_unreachable",
            "message" =>
              "Proxmox VE could not be reached, or it closed the connection before answering."
          }}}

    def run(_, _), do: {:error, :unsupported_request}
    def execute_job(_, _, _, _), do: {:error, :unsupported_request}
    def approve(_), do: {:error, :unsupported_request}
    def reject(_), do: {:error, :unsupported_request}
    def health, do: {:ok, %{status: "ok"}}
    def ready, do: {:ok, %{status: "ready"}}
  end

  defmodule HealthClient do
    @moduledoc false
    def proxmox_health(owner) do
      send(self(), {:health_owner, owner})
      reading()
    end

    defp reading,
      do:
        {:ok,
         %{
           "schema" => "proxmox-health.v1",
           "backups" => %{"ok" => true, "data" => %{"schema" => "proxmox-backups.v1"}},
           "disks" => [%{"node" => "pve-a", "result" => %{"ok" => true}}]
         }}

    def run(_, _), do: {:error, :unsupported_request}
    def execute_job(_, _, _, _), do: {:error, :unsupported_request}
    def approve(_), do: {:error, :unsupported_request}
    def reject(_), do: {:error, :unsupported_request}
    def health, do: {:ok, %{status: "ok"}}
    def ready, do: {:ok, %{status: "ready"}}
  end

  defmodule HealthReadFailedClient do
    @moduledoc false
    def proxmox_health(_owner),
      do:
        {:error,
         {:ai_service_error, 502,
          %{
            "error" => "proxmox_read_failed",
            "reason" => "provider_timeout",
            "message" => "Proxmox VE did not answer in time."
          }}}

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

  test "a failed read keeps its cause and fixed message", %{owner: owner} do
    Application.put_env(:itsm_backend, :ai_client, TypedReadFailedClient)

    response = owner |> conn_for() |> get("/api/v1/proxmox/overview") |> json_response(503)

    assert response == %{
             "error" => "proxmox_read_failed",
             "reason" => "provider_unreachable",
             "message" =>
               "Proxmox VE could not be reached, or it closed the connection before answering."
           }
  end

  test "backups and disk health need a signed-in account", %{conn: conn} do
    assert conn |> get("/api/v1/proxmox/health") |> json_response(401)
  end

  test "backups and disk health pass through for the owner", %{owner: owner} do
    Application.put_env(:itsm_backend, :ai_client, HealthClient)

    response = owner |> conn_for() |> get("/api/v1/proxmox/health") |> json_response(200)

    assert response["schema"] == "proxmox-health.v1"
    assert [%{"node" => "pve-a"}] = response["disks"]
    # The AI reads the signed-in account's own Proxmox link.
    user_id = owner.user["user_id"]
    assert_received {:health_owner, ^user_id}
  end

  test "an AI without the health read or a failed read stays unavailable with its cause", %{
    owner: owner
  } do
    response = owner |> conn_for() |> get("/api/v1/proxmox/health") |> json_response(503)
    assert response == %{"error" => "proxmox_dashboard_unavailable"}

    Application.put_env(:itsm_backend, :ai_client, HealthReadFailedClient)
    response = owner |> conn_for() |> get("/api/v1/proxmox/health") |> json_response(503)

    assert response == %{
             "error" => "proxmox_read_failed",
             "reason" => "provider_timeout",
             "message" => "Proxmox VE did not answer in time."
           }
  end

  defp conn_for(identity),
    do: build_conn() |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
end
