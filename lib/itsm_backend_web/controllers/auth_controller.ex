defmodule ItsmBackendWeb.AuthController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.Auth
  alias ItsmBackend.Auth.AccountsMailer
  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.AuthRequest

  def register(conn, params) do
    case Auth.register(params) do
      {:ok, user, token} ->
        delivery = mail_delivery(AccountsMailer.deliver_verification(user, token))

        conn
        |> put_status(:created)
        |> json(%{user: user, verification_required: true, mail_delivery: delivery})

      {:error, :email_taken} ->
        error(conn, :conflict, "email_taken")

      {:error, :registration_disabled} ->
        error(conn, :forbidden, "registration_disabled")

      {:error, :invalid_email} ->
        error(conn, :unprocessable_entity, "invalid_email")

      {:error, :invalid_password} ->
        error(conn, :unprocessable_entity, "invalid_password")

      {:error, _} ->
        error(conn, :unprocessable_entity, "invalid_registration")
    end
  end

  def verify_email(conn, %{"token" => token}) do
    case Auth.verify_email(token) do
      {:ok, user} -> json(conn, %{verified: true, user: user})
      {:error, _} -> error(conn, :unprocessable_entity, "invalid_or_expired_token")
    end
  end

  def verify_email(conn, _), do: error(conn, :unprocessable_entity, "invalid_request")

  def resend_verification(conn, %{"email" => email}) do
    case Auth.issue_verification(email) do
      {:ok, user, token} ->
        _ = AccountsMailer.deliver_verification(user, token)
        accepted(conn)

      {:ok, :not_applicable} ->
        accepted(conn)

      {:error, _} ->
        accepted(conn)
    end
  end

  def resend_verification(conn, _), do: accepted(conn)

  def login(conn, %{"email" => email, "password" => password}) do
    user_agent = get_req_header(conn, "user-agent") |> List.first()

    case Auth.login(email, password, user_agent) do
      {:ok, auth} ->
        config = RuntimeConfig.auth!()
        session = auth.session

        conn
        |> put_resp_cookie(config.cookie_name, auth.raw_token, cookie_options(config))
        |> json(%{
          user: auth.user,
          session_id: session["session_id"],
          expires_at: session["expires_at"],
          csrf_token: auth.csrf_token
        })

      {:error, :email_not_verified} ->
        error(conn, :forbidden, "email_not_verified")

      {:error, :account_disabled} ->
        error(conn, :forbidden, "account_disabled")

      {:error, _} ->
        error(conn, :unauthorized, "invalid_credentials")
    end
  end

  def login(conn, _), do: error(conn, :unprocessable_entity, "invalid_request")

  def me(conn, _params) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} ->
        json(conn, %{
          user: ctx.user,
          session_id: ctx.session["session_id"],
          expires_at: ctx.session["expires_at"],
          csrf_token: ctx.session["csrf_token"]
        })

      {:error, conn} ->
        conn
    end
  end

  def logout(conn, _params) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} ->
        _ = Auth.revoke_session(ctx.user["user_id"], ctx.session["session_id"])
        config = RuntimeConfig.auth!()

        conn
        |> delete_resp_cookie(config.cookie_name, path: "/")
        |> json(%{status: "logged_out"})

      {:error, conn} ->
        conn
    end
  end

  def forgot_password(conn, %{"email" => email}) do
    case Auth.issue_password_reset(email) do
      {:ok, user, token} ->
        _ = AccountsMailer.deliver_password_reset(user, token)
        accepted(conn)

      {:ok, :not_applicable} ->
        accepted(conn)

      {:error, _} ->
        accepted(conn)
    end
  end

  def forgot_password(conn, _), do: accepted(conn)

  def reset_password(conn, %{"token" => token, "new_password" => password}) do
    case Auth.reset_password(token, password) do
      :ok -> json(conn, %{status: "password_reset"})
      {:error, :invalid_password} -> error(conn, :unprocessable_entity, "invalid_password")
      {:error, _} -> error(conn, :unprocessable_entity, "invalid_or_expired_token")
    end
  end

  def reset_password(conn, _), do: error(conn, :unprocessable_entity, "invalid_request")

  defp cookie_options(config) do
    [
      http_only: true,
      secure: config.cookie_secure,
      same_site: config.cookie_same_site,
      max_age: config.session_ttl_seconds,
      path: "/"
    ]
  end

  defp mail_delivery({:ok, _}), do: "sent"
  defp mail_delivery({:error, _}), do: "failed"

  defp accepted(conn), do: conn |> put_status(:accepted) |> json(%{status: "accepted"})
  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
