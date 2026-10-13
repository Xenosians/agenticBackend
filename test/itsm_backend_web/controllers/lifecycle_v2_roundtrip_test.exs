defmodule ItsmBackendWeb.LifecycleV2RoundtripTest do
  use ItsmBackendWeb.ConnCase, async: false
  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job
  alias ItsmBackendWeb.AuthTestSupport

  setup do
    original = Application.get_env(:itsm_backend, :internal_job_token)
    Application.put_env(:itsm_backend, :internal_job_token, "lifecycle-v2-test")
    on_exit(fn -> Application.put_env(:itsm_backend, :internal_job_token, original) end)
    %{identity: AuthTestSupport.authenticated_identity!()}
  end

  test "denial and unknown outcomes persist, replay safely, and project by API version", %{
    identity: identity
  } do
    for status <- ["denied", "outcome_unknown"] do
      {:ok, job} =
        Jobs.create(%{
          user_id: identity.user["user_id"],
          conversation_id: identity.chat["chat_id"],
          message: "Lifecycle test"
        })

      {:ok, processing} = Job.claim(job, 60)
      {:ok, _} = Jobs.update(processing)

      payload = %{
        "contract_version" => 2,
        "attempt" => 1,
        "status" => status,
        "selected_agent" => nil,
        "proposed_tool" => nil,
        "error" => "Trusted execution detail"
      }

      callback = fn body ->
        build_conn()
        |> put_req_header("x-internal-token", "lifecycle-v2-test")
        |> post("/api/internal/v1/jobs/#{job.id}/completion", body)
      end

      assert json_response(callback.(payload), 200)["acknowledgement"] == "applied"
      assert json_response(callback.(payload), 200)["acknowledgement"] == "duplicate"

      assert json_response(callback.(%{payload | "attempt" => 2}), 409)["error"] ==
               "stale_attempt"

      late = %{
        "attempt" => 1,
        "status" => "completed",
        "selected_agent" => nil,
        "proposed_tool" => nil,
        "result" => %{"answer" => "late"}
      }

      assert json_response(callback.(late), 200)["acknowledgement"] == "duplicate"
      {:ok, stored} = Jobs.get(job.id)
      assert stored.status == status
      assert stored.result == nil
      assert {:error, _} = Job.claim(stored, 60)

      for version <- [1, 2] do
        response =
          build_conn()
          |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
          |> get("/api/v#{version}/jobs/#{job.id}")
          |> json_response(200)

        expected =
          if version == 2,
            do: status,
            else: if(status == "denied", do: "failed", else: "reconciliation_required")

        assert response["status"] == expected
        assert response["error"] == "Trusted execution detail"
      end

      assert build_conn() |> get("/api/v2/jobs/#{job.id}") |> json_response(401)

      history =
        build_conn()
        |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
        |> get("/api/v2/chats/#{identity.chat["chat_id"]}/history")
        |> json_response(200)

      assert Enum.any?(
               history["messages"],
               &(&1["job_id"] == job.id and &1["role"] == "assistant" and &1["status"] == status)
             )

      rejected =
        build_conn()
        |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
        |> post("/api/v2/jobs/#{job.id}/approve", %{})
        |> json_response(409)

      assert rejected["error"] == "job_not_waiting_approval"
    end
  end
end
