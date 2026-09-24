defmodule ItsmBackendWeb.JobControllerContractTest do
  use ItsmBackendWeb.ConnCase,
    async: false

  alias ItsmBackend.Jobs
  alias ItsmBackendWeb.AuthTestSupport

  setup %{conn: conn} do
    identity =
      AuthTestSupport.authenticated_identity!()

    authenticated_conn =
      AuthTestSupport.bearer_conn(
        conn,
        identity.auth.raw_token
      )

    {:ok, conn: authenticated_conn, user: identity.user, chat: identity.chat}
  end

  test "creates durable job through authenticated public contract",
       %{
         conn: conn,
         user: user,
         chat: chat
       } do
    conn =
      post(
        conn,
        ~p"/api/v1/jobs",
        %{
          "chat_id" => chat["chat_id"],
          "message" => "Create a durable job."
        }
      )

    response =
      json_response(
        conn,
        202
      )

    assert response["status"] ==
             "pending"

    assert is_binary(response["job_id"])

    assert response["job_id"] != ""

    assert {:ok, stored_job} =
             Jobs.get(response["job_id"])

    assert stored_job.user_id ==
             user["user_id"]

    assert stored_job.message ==
             "Create a durable job."

    assert stored_job.status ==
             "pending"

    assert stored_job.conversation_id ==
             chat["chat_id"]
  end

  test "rejects blank chat id",
       %{conn: conn} do
    conn =
      post(
        conn,
        ~p"/api/v1/jobs",
        %{
          "chat_id" => "",
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

  test "rejects browser supplied user identity",
       %{
         conn: conn,
         chat: chat
       } do
    conn =
      post(
        conn,
        ~p"/api/v1/jobs",
        %{
          "chat_id" => chat["chat_id"],
          "message" => "This must be rejected.",
          "user_id" => "forged-user-id"
        }
      )

    assert json_response(
             conn,
             422
           ) == %{
             "error" => "invalid_request"
           }
  end

  test "rejects unknown create request fields",
       %{
         conn: conn,
         chat: chat
       } do
    conn =
      post(
        conn,
        ~p"/api/v1/jobs",
        %{
          "chat_id" => chat["chat_id"],
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

  test "requires authentication",
       %{chat: chat} do
    conn =
      build_conn()
      |> post(
        ~p"/api/v1/jobs",
        %{
          "chat_id" => chat["chat_id"],
          "message" => "Unauthenticated request."
        }
      )

    assert json_response(
             conn,
             401
           ) == %{
             "error" => "authentication_required"
           }
  end
end
