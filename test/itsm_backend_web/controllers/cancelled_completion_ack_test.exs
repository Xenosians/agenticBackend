defmodule ItsmBackendWeb.CancelledCompletionAckTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job

  # The AI may have saved its completion before the owner's cancel reached
  # it. That late delivery must be acknowledged once as a duplicate, with a
  # contract-valid acknowledgement, so the AI's outbox can drop it.

  setup do
    original = Application.get_env(:itsm_backend, :internal_job_token)
    Application.put_env(:itsm_backend, :internal_job_token, "cancel-ack-test")
    on_exit(fn -> Application.put_env(:itsm_backend, :internal_job_token, original) end)
    :ok
  end

  test "a late completion of a cancelled job is acknowledged as a duplicate" do
    {:ok, job} = Jobs.create(%{user_id: "cancel-ack-test", message: "Cancel me"})
    {:ok, processing} = Job.claim(job, 60)
    {:ok, processing} = Jobs.update(processing)
    {:ok, _cancelled, :processing} = Jobs.cancel(processing)

    for version <- [2, 1] do
      payload =
        %{
          "attempt" => processing.attempts,
          "status" => "completed",
          "selected_agent" => nil,
          "proposed_tool" => nil,
          "result" => %{"answer" => "late"}
        }
        |> then(&if(version == 2, do: Map.put(&1, "contract_version", 2), else: &1))

      ack =
        build_conn()
        |> put_req_header("x-internal-token", "cancel-ack-test")
        |> post("/api/internal/v1/jobs/#{job.id}/completion", payload)
        |> json_response(200)

      assert ack["acknowledgement"] == "duplicate"
      assert ack["status"] == if(version == 2, do: "cancelled", else: "failed")
    end

    assert {:ok, %{status: "cancelled", result: nil}} = Jobs.get(job.id)
  end
end
