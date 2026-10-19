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

  test "retrying the same submission recovers its durable job and rejects changed content",
       %{conn: conn, user: user, chat: chat} do
    payload = %{
      "chat_id" => chat["chat_id"],
      "message" => "A pinned submission.",
      "submission_id" => ItsmBackend.SubmissionTestSupport.identity()
    }

    # Ignore the first acknowledgement, as a disconnected browser would.
    first = conn |> post(~p"/api/v1/jobs", payload) |> json_response(202)
    replay = conn |> recycle() |> post(~p"/api/v1/jobs", payload) |> json_response(202)
    assert replay["job_id"] == first["job_id"]
    assert replay["submission_id"] == payload["submission_id"]
    assert {:ok, [only_job]} = Jobs.list_by_conversation(user["user_id"], chat["chat_id"])
    assert only_job.id == first["job_id"]

    rejected =
      conn |> recycle() |> post(~p"/api/v1/jobs", %{payload | "message" => "Changed action."})

    assert json_response(rejected, 409)["error"] == "submission_conflict"
  end

  test "replayed completed submission reports its saved state without queuing another job",
       %{conn: conn, chat: chat} do
    payload = %{
      "chat_id" => chat["chat_id"],
      "message" => "Recover this completed submission.",
      "submission_id" => ItsmBackend.SubmissionTestSupport.identity()
    }

    first = conn |> post(~p"/api/v1/jobs", payload) |> json_response(202)
    assert {:ok, stored} = Jobs.get(first["job_id"])
    assert {:ok, processing} = ItsmBackend.Jobs.Job.claim(stored, 60)
    assert {:ok, completed} = ItsmBackend.Jobs.Job.transition(processing, "completed")
    assert {:ok, _} = ItsmBackend.Jobs.SurrealStore.update(completed)
    replay = conn |> recycle() |> post(~p"/api/v1/jobs", payload) |> json_response(202)
    assert replay["job_id"] == first["job_id"]
    assert replay["status"] == "completed"
    assert {:ok, unchanged} = Jobs.get(first["job_id"])
    assert unchanged.attempts == 1
  end

  test "binds a storage-record chat alias to its canonical conversation history",
       %{conn: conn, user: user, chat: chat} do
    conn =
      post(conn, ~p"/api/v1/jobs", %{
        "chat_id" => chat["id"],
        "message" => "Keep this request in the authorized chat history."
      })

    response = json_response(conn, 202)
    assert {:ok, job} = Jobs.get(response["job_id"])
    assert job.conversation_id == chat["chat_id"]

    assert {:ok, messages} = ItsmBackend.Chats.history(user, chat["chat_id"], 100, 2)
    assert Enum.any?(messages, &(&1["job_id"] == job.id))
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
