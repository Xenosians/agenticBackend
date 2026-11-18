defmodule ItsmBackendWeb.ProxmoxActionControllerTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackendWeb.AuthTestSupport
  alias ItsmBackendWeb.ProxmoxActionTestClient

  @proposal %{
    "status" => "approval_required",
    "approval_id" => "a1b2c3d4",
    "tool" => "proxmox_guest_start",
    "action" => "start",
    "risk" => "medium",
    "node" => "hummingbird",
    "vmid" => 990,
    "type" => "lxc",
    "name" => "janus-lab",
    "approval_text" =>
      "Start LXC 990 (janus-lab) on Proxmox node hummingbird. It boots the guest. " <>
        "Janus waits for the Proxmox task and reads the guest back."
  }

  @executed %{
    "approval_id" => "a1b2c3d4",
    "protocol_status" => "processed",
    "execution_status" => "succeeded",
    "approval_status" => "approved",
    "replayed" => false,
    "result" => %{
      "ok" => true,
      "status" => "executed",
      "action" => "start",
      "node" => "hummingbird",
      "vmid" => 990,
      "type" => "lxc",
      "name" => "janus-lab",
      "expected_status" => "running",
      "observed_status" => "running",
      "upid" => "UPID:hummingbird:0001:0002:0003:vzstart:990:janus@pve!dashboard:",
      "task_exit_status" => "OK",
      "verification_ok" => true,
      "observed_at" => "2026-11-16T03:00:00+00:00"
    },
    "error" => nil
  }

  @deleted %{
    "approval_id" => "a1b2c3d4",
    "protocol_status" => "processed",
    "execution_status" => "succeeded",
    "approval_status" => "approved",
    "replayed" => false,
    "result" => %{
      "ok" => true,
      "status" => "executed",
      "node" => "hummingbird",
      "vmid" => 990,
      "type" => "lxc",
      "name" => "janus-lab",
      "deleted" => true,
      "changed" => true,
      "verification_ok" => true,
      "retry_safe" => false,
      "upid" => "UPID:hummingbird:0004:0005:0006:vzdestroy:990:janus@pve!dashboard:",
      "observed_at" => "2026-11-16T03:05:00+00:00"
    },
    "error" => nil
  }

  setup do
    keys = [
      :ai_client,
      :proxmox_test_propose,
      :proxmox_test_approve,
      :proxmox_test_reject,
      :proxmox_test_listener
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:itsm_backend, &1)})
    Application.put_env(:itsm_backend, :ai_client, ProxmoxActionTestClient)
    Application.put_env(:itsm_backend, :proxmox_test_listener, self())
    Application.put_env(:itsm_backend, :proxmox_test_propose, {:ok, @proposal})
    Application.put_env(:itsm_backend, :proxmox_test_approve, {:ok, @executed})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:itsm_backend, key)
        {key, value} -> Application.put_env(:itsm_backend, key, value)
      end)
    end)

    %{owner: AuthTestSupport.authenticated_identity!()}
  end

  test "actions require a signed-in account", %{conn: conn} do
    assert conn |> get("/api/v1/proxmox/actions") |> json_response(401)
    assert conn |> post("/api/v1/proxmox/actions", propose_body()) |> json_response(401)
  end

  test "a proposal records the exact target and waits for the owner's decision", %{owner: owner} do
    response =
      owner |> conn_for() |> post("/api/v1/proxmox/actions", propose_body()) |> json_response(201)

    assert_received {:proxmox_propose, user_id, "hummingbird", 990, "start", %{}}
    assert user_id == owner.user["user_id"]
    assert response["status"] == "waiting_approval"
    assert response["action"] == "start"

    assert {response["node"], response["vmid"], response["type"], response["name"]} ==
             {"hummingbird", 990, "lxc", "janus-lab"}

    assert response["approval_text"] == @proposal["approval_text"]
    refute Map.has_key?(response, "approval_id")
    refute_received {:ai_approval_decision, _, _, _}
  end

  test "the same submission is proposed once and returns the same action", %{owner: owner} do
    body = propose_body()
    first = owner |> conn_for() |> post("/api/v1/proxmox/actions", body) |> json_response(201)
    second = owner |> conn_for() |> post("/api/v1/proxmox/actions", body) |> json_response(200)

    assert first["action_id"] == second["action_id"]
    assert_received {:proxmox_propose, _, _, _, _, _}
    refute_received {:proxmox_propose, _, _, _, _, _}

    changed = Map.put(body, "action", "reboot")

    assert owner |> conn_for() |> post("/api/v1/proxmox/actions", changed) |> json_response(409) ==
             %{"error" => "proxmox_action_conflict"}
  end

  test "approving runs the action once and keeps its read-back receipt", %{owner: owner} do
    created =
      owner |> conn_for() |> post("/api/v1/proxmox/actions", propose_body()) |> json_response(201)

    approved =
      owner
      |> conn_for()
      |> post("/api/v1/proxmox/actions/#{created["action_id"]}/approve", %{})
      |> json_response(200)

    assert_received {:ai_approval_decision, :approve, "a1b2c3d4", nil}
    assert approved["status"] == "succeeded"
    assert approved["observed_status"] == "running"
    assert approved["verification_ok"] == true
    assert approved["upid"] =~ "UPID:hummingbird:"

    again =
      owner
      |> conn_for()
      |> post("/api/v1/proxmox/actions/#{created["action_id"]}/approve", %{})
      |> json_response(200)

    assert again["status"] == "succeeded"
    refute_received {:ai_approval_decision, :approve, _, _}

    [listed] =
      owner
      |> conn_for()
      |> get("/api/v1/proxmox/actions")
      |> json_response(200)
      |> Map.fetch!("actions")

    assert listed["action_id"] == created["action_id"]
    assert listed["status"] == "succeeded"
  end

  test "an action without a confirmed outcome is never retried", %{owner: owner} do
    Application.put_env(
      :itsm_backend,
      :proxmox_test_approve,
      {:error, {:request_failed, :timeout}}
    )

    created =
      owner |> conn_for() |> post("/api/v1/proxmox/actions", propose_body()) |> json_response(201)

    path = "/api/v1/proxmox/actions/#{created["action_id"]}/approve"

    first = owner |> conn_for() |> post(path, %{}) |> json_response(202)
    assert first["status"] == "outcome_unknown"
    assert_received {:ai_approval_decision, :approve, "a1b2c3d4", nil}

    second = owner |> conn_for() |> post(path, %{}) |> json_response(202)
    assert second["status"] == "outcome_unknown"
    refute_received {:ai_approval_decision, :approve, _, _}
  end

  test "rejecting closes the proposal without running it", %{owner: owner} do
    Application.put_env(
      :itsm_backend,
      :proxmox_test_reject,
      {:ok,
       %{
         "approval_id" => "a1b2c3d4",
         "protocol_status" => "processed",
         "execution_status" => "rejected",
         "approval_status" => "rejected",
         "replayed" => false,
         "result" => nil,
         "error" => "Action rejected by the user. No tool was executed."
       }}
    )

    created =
      owner |> conn_for() |> post("/api/v1/proxmox/actions", propose_body()) |> json_response(201)

    rejected =
      owner
      |> conn_for()
      |> post("/api/v1/proxmox/actions/#{created["action_id"]}/reject", %{})
      |> json_response(200)

    assert rejected["status"] == "rejected"
    assert_received {:ai_approval_decision, :reject, "a1b2c3d4", nil}
    refute_received {:ai_approval_decision, :approve, _, _}

    assert owner
           |> conn_for()
           |> post("/api/v1/proxmox/actions/#{created["action_id"]}/approve", %{})
           |> json_response(409) == %{"error" => "proxmox_action_already_decided"}
  end

  test "another account cannot see or decide the owner's action", %{owner: owner} do
    created =
      owner |> conn_for() |> post("/api/v1/proxmox/actions", propose_body()) |> json_response(201)

    stranger = AuthTestSupport.authenticated_identity!()

    assert stranger
           |> conn_for()
           |> post("/api/v1/proxmox/actions/#{created["action_id"]}/approve", %{})
           |> json_response(404) == %{"error" => "proxmox_action_not_found"}

    refute_received {:ai_approval_decision, _, _, _}

    assert stranger |> conn_for() |> get("/api/v1/proxmox/actions") |> json_response(200) == %{
             "actions" => []
           }
  end

  test "a refused proposal says why and records nothing", %{owner: owner} do
    Application.put_env(
      :itsm_backend,
      :proxmox_test_propose,
      {:error,
       {:ai_service_error, 409,
        %{
          "detail" => %{
            "code" => "proxmox_action_refused",
            "message" => "LXC 990 (janus-lab) is already running."
          }
        }}}
    )

    response =
      owner |> conn_for() |> post("/api/v1/proxmox/actions", propose_body()) |> json_response(409)

    assert response == %{
             "error" => "proxmox_action_refused",
             "message" => "LXC 990 (janus-lab) is already running."
           }

    assert owner |> conn_for() |> get("/api/v1/proxmox/actions") |> json_response(200) == %{
             "actions" => []
           }
  end

  test "only an exact node, a valid VMID and a known action are accepted", %{owner: owner} do
    for change <- [
          %{"action" => "migrate"},
          %{"vmid" => "990"},
          %{"vmid" => 0},
          %{"node" => "../x"},
          %{"submission_id" => "not-a-uuid"}
        ] do
      body = Map.merge(propose_body(), change)

      assert owner |> conn_for() |> post("/api/v1/proxmox/actions", body) |> json_response(422) ==
               %{"error" => "invalid_proxmox_action"}
    end

    refute_received {:proxmox_propose, _, _, _, _, _}
  end

  test "a change carries its own values to the approval and waits like a power action", %{
    owner: owner
  } do
    Application.put_env(
      :itsm_backend,
      :proxmox_test_propose,
      {:ok,
       %{
         @proposal
         | "tool" => "proxmox_guest_set_options",
           "action" => "set_options",
           "approval_text" =>
             "Set LXC 990 (janus-lab) tags to 'db,prod' and start at boot on Proxmox node hummingbird."
       }}
    )

    body =
      Map.merge(propose_body(), %{
        "action" => "set_options",
        "tags" => "db, prod",
        "on_boot" => true
      })

    response = owner |> conn_for() |> post("/api/v1/proxmox/actions", body) |> json_response(201)

    assert_received {:proxmox_propose, _, "hummingbird", 990, "set_options",
                     %{"tags" => "db, prod", "on_boot" => true}}

    assert response["status"] == "waiting_approval"
    assert response["action"] == "set_options"
    assert response["destructive"] == false
  end

  test "a destructive change needs the owner's typed guest name before anything is sent", %{
    owner: owner
  } do
    Application.put_env(
      :itsm_backend,
      :proxmox_test_propose,
      {:ok,
       %{
         @proposal
         | "tool" => "proxmox_guest_delete",
           "action" => "delete",
           "approval_text" => "Delete LXC 990 (janus-lab) on Proxmox node hummingbird."
       }}
    )

    Application.put_env(:itsm_backend, :proxmox_test_approve, {:ok, @deleted})

    created =
      owner
      |> conn_for()
      |> post("/api/v1/proxmox/actions", Map.merge(propose_body(), %{"action" => "delete"}))
      |> json_response(201)

    assert created["destructive"] == true
    path = "/api/v1/proxmox/actions/#{created["action_id"]}/approve"

    assert owner |> conn_for() |> post(path, %{}) |> json_response(409) ==
             %{"error" => "proxmox_confirmation_required"}

    assert owner
           |> conn_for()
           |> post(path, %{"confirm_name" => "something-else"})
           |> json_response(409) == %{"error" => "proxmox_confirmation_mismatch"}

    refute_received {:ai_approval_decision, _, _, _}

    approved =
      owner |> conn_for() |> post(path, %{"confirm_name" => "janus-lab"}) |> json_response(200)

    assert_received {:ai_approval_decision, :approve, "a1b2c3d4", "janus-lab"}
    assert approved["status"] == "succeeded"
    assert approved["verification_ok"] == true
  end

  test "a new guest takes the free VMID the AI prepared", %{owner: owner} do
    Application.put_env(
      :itsm_backend,
      :proxmox_test_propose,
      {:ok,
       Map.merge(@proposal, %{
         "tool" => "proxmox_guest_create",
         "action" => "create",
         "vmid" => 992,
         "new_vmid" => 992,
         "name" => "lab-2",
         "approval_text" =>
           "Create LXC 992 (lab-2) on Proxmox node hummingbird. Janus asked Proxmox for the next free VMID."
       })}
    )

    body =
      Map.merge(propose_body(), %{
        "action" => "create",
        "vmid" => nil,
        "hostname" => "lab-2",
        "template" => "local:vztmpl/alpine-3.23-default_20260116_amd64.tar.xz",
        "cores" => 1,
        "memory_mib" => 128,
        "disk_gib" => 2,
        "storage" => "local-lvm"
      })

    response = owner |> conn_for() |> post("/api/v1/proxmox/actions", body) |> json_response(201)

    assert_received {:proxmox_propose, _, "hummingbird", nil, "create", %{"hostname" => "lab-2"}}
    assert response["vmid"] == 992
    assert response["new_vmid"] == 992
    assert response["status"] == "waiting_approval"
  end

  defp propose_body do
    %{
      "node" => "hummingbird",
      "vmid" => 990,
      "action" => "start",
      "submission_id" => "6f1c2a4e-1b2c-4d3e-8f9a-0b1c2d3e4f5a"
    }
  end

  defp conn_for(identity),
    do: build_conn() |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
end
