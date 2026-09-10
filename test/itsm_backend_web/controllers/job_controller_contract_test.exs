defmodule ItsmBackendWeb.JobControllerContractTest do
  use ItsmBackendWeb.ConnCase,
    async: false

  alias ItsmBackend.Jobs

  # ------------------------------------------------------------
  # Valid create request
  # ------------------------------------------------------------

  test "creates durable job through canonical public contract",
       %{conn: conn} do
    conn =
      post(
        conn,
        ~p"/api/v1/jobs",
        %{
          "user_id" => "public-contract-user",
          "message" => "Create a durable job."
        }
      )

    response =
      json_response(
        conn,
        202
      )

    assert response[
             "status"
           ] == "pending"

    assert is_binary(
             response[
               "job_id"
             ]
           )

    assert response[
             "job_id"
           ] != ""

    assert {:ok, stored_job} =
             Jobs.get(
               response[
                 "job_id"
               ]
             )

    assert stored_job.user_id ==
             "public-contract-user"

    assert stored_job.message ==
             "Create a durable job."

    assert stored_job.status ==
             "pending"

    assert stored_job.conversation_id ==
             nil
  end

  # ------------------------------------------------------------
  # Explicit blank optional field
  # ------------------------------------------------------------

  test "rejects explicitly blank conversation id",
       %{conn: conn} do
    conn =
      post(
        conn,
        ~p"/api/v1/jobs",
        %{
          "user_id" => "public-contract-user",
          "conversation_id" => "",
          "message" => "This must be rejected."
        }
      )

    assert json_response(
             conn,
             422
           ) == %{
             "error" => "invalid_request"
           }
  end

  # ------------------------------------------------------------
  # Unknown wire field
  # ------------------------------------------------------------

  test "rejects unknown create request fields",
       %{conn: conn} do
    conn =
      post(
        conn,
        ~p"/api/v1/jobs",
        %{
          "user_id" => "public-contract-user",
          "message" => "This must be rejected.",
          "debug" => true
        }
      )

    assert json_response(
             conn,
             422
           ) == %{
             "error" => "invalid_request"
           }
  end
end
