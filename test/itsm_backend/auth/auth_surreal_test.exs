defmodule ItsmBackend.Auth.AuthSurrealTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Auth
  alias ItsmBackend.Chats

  test "registers, verifies, logs in, creates a chat and lists session history" do
    suffix = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)
    email = "auth-#{suffix}@example.test"
    password = "correct horse battery #{suffix}!"

    assert {:ok, user, verification_token} =
             Auth.register(%{
               "email" => email,
               "display_name" => "Auth Test #{suffix}",
               "password" => password
             })

    assert user["status"] == "pending_verification"
    assert {:ok, verified} = Auth.verify_email(verification_token)
    assert verified["status"] == "active"

    assert {:ok, auth} = Auth.login(email, password, "ExUnit")
    assert auth.user["user_id"] == verified["user_id"]
    assert is_binary(auth.raw_token)
    assert is_binary(auth.csrf_token)

    assert {:ok, session_user, session} = Auth.authenticate_session(auth.raw_token)
    assert session_user["user_id"] == verified["user_id"]

    assert {:ok, chat} = Chats.create(session_user, %{"title" => "Integration test"})
    assert chat["user_id"] == verified["user_id"]

    assert {:ok, sessions} = Auth.list_sessions(verified["user_id"], session["session_id"])
    assert Enum.any?(sessions, &(&1["current"] == true))
  end
end
