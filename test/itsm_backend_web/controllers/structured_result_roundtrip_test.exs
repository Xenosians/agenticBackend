defmodule ItsmBackendWeb.StructuredResultRoundtripTest do
  use ItsmBackendWeb.ConnCase,
    async: false

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Job

  @internal_token "structured-result-roundtrip-token"

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

  test "structured tool result survives completion persistence and public response",
       %{conn: conn} do
    # ----------------------------------------------------------
    # Create durable job
    # ----------------------------------------------------------

    assert {:ok, created_job} =
             Jobs.create(%{
               user_id:
                 "structured-result-user",

               message:
                 "Check workspace services."
             })

    # ----------------------------------------------------------
    # Move exact job into processing
    # ----------------------------------------------------------

    assert {:ok, processing_job} =
             Job.claim(
               created_job,
               60
             )

    assert {:ok, processing_job} =
             Jobs.update(
               processing_job
             )

    # ----------------------------------------------------------
    # Representative AI HubResult-shaped structured result
    #
    # Phoenix intentionally does not understand the semantics of
    # service_status or result-card.v1.
    # ----------------------------------------------------------

    structured_result = %{
      "status" =>
        "success",

      "user_request" =>
        "Check workspace services.",

      "routes" => [
        "developer-specialist"
      ],

      "results" => [
        %{
          "task_id" =>
            "task-structured-001",

          "agent_name" =>
            "developer-specialist",

          "status" =>
            "success",

          "answer" =>
            "Workspace service status:\n- samba-ad: state=running",

          "proposed_tool" =>
            "workspace_service_status",

          "proposed_arguments" =>
            %{},

          "error" =>
            nil,

          "approval_id" =>
            nil,

          "tool_result" => %{
            "ok" =>
              true,

            "status" =>
              "success",

            "provider" =>
              "docker_compose",

            "services" => [
              %{
                "service" =>
                  "samba-ad",

                "container" =>
                  "itsm-samba-ad",

                "state" =>
                  "running",

                "status" =>
                  "Up 2 minutes",

                "health" =>
                  nil
              }
            ],

            "service_count" =>
              1,

            "error" =>
              nil
          },

          "presentation" => %{
            "schema" =>
              "result-card.v1",

            "kind" =>
              "service_status",

            "title" =>
              "Workspace services",

            "status" =>
              "success",

            "fields" => [
              %{
                "label" =>
                  "Provider",

                "value" =>
                  "docker_compose"
              },

              %{
                "label" =>
                  "Services",

                "value" =>
                  "1"
              }
            ],

            "sections" => [
              %{
                "kind" =>
                  "list",

                "title" =>
                  "Services",

                "content" => [
                  (
                    "samba-ad: "
                    <> "state=running, "
                    <> "status=Up 2 minutes"
                  )
                ]
              }
            ]
          }
        }
      ],

      "answer" =>
        "The samba-ad workspace service is running.",

      "error" =>
        nil
    }

    completion_payload = %{
      "attempt" =>
        processing_job.attempts,

      "status" =>
        "completed",

      "selected_agent" =>
        "developer-specialist",

      "proposed_tool" =>
        nil,

      "result" =>
        structured_result
    }

    # ----------------------------------------------------------
    # AI -> Phoenix durable completion
    # ----------------------------------------------------------

    completion_conn =
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
        ~p"/api/internal/v1/jobs/#{processing_job.id}/completion",
        Jason.encode!(
          completion_payload
        )
      )

    assert json_response(
             completion_conn,
             200
           ) == %{
             "job_id" =>
               processing_job.id,

             "status" =>
               "completed",

             "acknowledgement" =>
               "applied"
           }

    # ----------------------------------------------------------
    # Public frontend-facing durable job response
    # ----------------------------------------------------------

    public_conn =
      build_conn()
      |> get(
        ~p"/api/v1/jobs/#{processing_job.id}"
      )

    response =
      json_response(
        public_conn,
        200
      )

    assert response[
             "status"
           ] == "completed"

    assert response[
             "selected_agent"
           ] == "developer-specialist"

    assert response[
             "result"
           ] == structured_result

    # ----------------------------------------------------------
    # Explicitly verify trusted raw machine data survived.
    # ----------------------------------------------------------

    [
      specialist_result
    ] =
      response[
        "result"
      ][
        "results"
      ]

    assert specialist_result[
             "tool_result"
           ][
             "provider"
           ] == "docker_compose"

    assert specialist_result[
             "tool_result"
           ][
             "service_count"
           ] == 1

    # ----------------------------------------------------------
    # Explicitly verify generic presentation survived.
    # ----------------------------------------------------------

    presentation =
      specialist_result[
        "presentation"
      ]

    assert presentation[
             "schema"
           ] == "result-card.v1"

    assert presentation[
             "kind"
           ] == "service_status"

    assert presentation[
             "title"
           ] == "Workspace services"

    assert presentation[
             "sections"
           ] == [
             %{
               "kind" =>
                 "list",

               "title" =>
                 "Services",

               "content" => [
                 (
                   "samba-ad: "
                   <> "state=running, "
                   <> "status=Up 2 minutes"
                 )
               ]
             }
           ]
  end

  # ------------------------------------------------------------
  # Environment restoration
  # ------------------------------------------------------------

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
