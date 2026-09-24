defmodule ItsmBackendWeb.AuthTestSupport do
  @moduledoc false

  import Plug.Conn

  alias ItsmBackend.Auth
  alias ItsmBackend.Chats

  def authenticated_identity! do
    suffix =
      6
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    email =
      "test-#{suffix}@example.test"

    password =
      "correct horse battery #{suffix}!"

    {:ok, _pending_user, verification_token} =
      Auth.register(%{
        "email" => email,
        "display_name" => "Test User #{suffix}",
        "password" => password
      })

    {:ok, user} =
      Auth.verify_email(verification_token)

    {:ok, auth} =
      Auth.login(
        email,
        password,
        "ExUnit"
      )

    {:ok, chat} =
      Chats.create(
        user,
        %{
          "title" => "Test chat #{suffix}"
        }
      )

    %{
      user: user,
      auth: auth,
      chat: chat
    }
  end

  def bearer_conn(
        conn,
        raw_token
      )
      when is_binary(raw_token) do
    put_req_header(
      conn,
      "authorization",
      "Bearer " <> raw_token
    )
  end
end
