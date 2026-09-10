defmodule ItsmBackendWeb.JobCompletionControllerContractTest do
  use ItsmBackendWeb.ConnCase,
    async: false

  @internal_token "completion-contract-test-token"

  setup do
    original_token =
      Application.get_env(
        :itsm_backend,
        :internal_job_token
      )

    Application.put_env(
      :itsm_backend,
      :internal_job_token,
      @internal_token
    )

    on_exit(fn ->
      restore_env(
        :internal_job_token,
        original_token
      )
    end)

    :ok
  end

  test "rejects invalid completion before durable job lookup",
       %{conn: conn} do
    conn =
      post_completion(
        conn,
        %{
          "attempt" => 1,
          "status" => "completed",
          "selected_agent" => "account",
          "proposed_tool" => nil
        }
      )

    assert json_response(
             conn,
             422
           ) == %{
             "error" => "invalid_completion_payload"
           }
  end

  test "rejects malformed proposed tool before durable job lookup",
       %{conn: conn} do
    conn =
      post_completion(
        conn,
        %{
          "attempt" => 1,
          "status" => "waiting_approval",
          "selected_agent" => "developer",
          "proposed_tool" => %{
            "tool" => "workspace_mkdir"
          },
          "result" => %{
            "status" => "approval_required"
          }
        }
      )

    assert json_response(
             conn,
             422
           ) == %{
             "error" => "invalid_completion_payload"
           }
  end

  defp post_completion(
         conn,
         payload
       ) do
    conn
    |> Plug.Conn.put_req_header(
      "content-type",
      "application/json"
    )
    |> Plug.Conn.put_req_header(
      "x-internal-token",
      @internal_token
    )
    |> post(
      ~p"/api/internal/v1/jobs/nonexistent-job/completion",
      Jason.encode!(payload)
    )
  end

  defp restore_env(
         key,
         nil
       ) do
    Application.delete_env(
      :itsm_backend,
      key
    )
  end

  defp restore_env(
         key,
         value
       ) do
    Application.put_env(
      :itsm_backend,
      key,
      value
    )
  end
end
