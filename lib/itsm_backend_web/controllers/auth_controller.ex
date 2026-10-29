defmodule ItsmBackendWeb.AuthController do
  use ItsmBackendWeb, :controller

  use ItsmBackendWeb.RequestContract

  request_contract(:register,
    required_body: ["email", "display_name", "password"]
  )

  request_contract(:verify_email,
    required_body: ["token"]
  )

  # The pending account is identified by this browser's verification cookie,
  # never by an address typed into the request.
  request_contract(:resend_verification, [])
  request_contract(:verification_status, [])

  request_contract(:login,
    required_body: ["email", "password"]
  )

  request_contract(:me, [])
  request_contract(:logout, [])

  request_contract(:forgot_password,
    required_body: ["email"]
  )

  request_contract(:reset_password,
    required_body: ["token", "new_password"]
  )

  require Logger

  alias ItsmBackend.Auth
  alias ItsmBackend.Auth.AccountsMailer
  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.AuthRequest
  alias ItsmBackendWeb.PublicError

  def register(conn, params) do
    case Auth.register(params) do
      {:ok, user, token, verification} ->
        delivery = mail_delivery(AccountsMailer.deliver_verification(user, token))

        conn
        |> put_verification_cookie(user["user_id"])
        |> put_status(:created)
        |> json(%{
          user: user,
          verification_required: true,
          mail_delivery: delivery,
          resend_after_seconds: verification.resend_after_seconds,
          email_hint: verification.email_hint
        })

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
      {:ok, user} ->
        conn
        |> delete_verification_cookie()
        |> json(%{verified: true, user: user})

      {:error, _} ->
        error(conn, :unprocessable_entity, "invalid_or_expired_token")
    end
  end

  def verify_email(conn, _), do: error(conn, :unprocessable_entity, "invalid_request")

  def verification_status(conn, _params) do
    with {:ok, user_id} <- verification_owner(conn),
         {:ok, verification} <- Auth.verification_status(user_id) do
      case verification do
        %{status: "verified"} ->
          conn |> delete_verification_cookie() |> json(%{status: "verified"})

        pending ->
          json(conn, pending)
      end
    else
      {:error, :not_pending} -> not_pending(conn)
      {:error, reason} -> verification_unavailable(conn, reason)
    end
  end

  def resend_verification(conn, _params) do
    with {:ok, user_id} <- verification_owner(conn),
         {:ok, user, token, verification} <- Auth.resend_verification(user_id) do
      delivery = mail_delivery(AccountsMailer.deliver_verification(user, token))

      conn
      |> put_status(:accepted)
      |> json(%{
        status: "sent",
        mail_delivery: delivery,
        resend_after_seconds: verification.resend_after_seconds,
        email_hint: verification.email_hint
      })
    else
      {:error, {:too_soon, seconds}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> put_status(:too_many_requests)
        |> json(%{error: "verification_resend_too_soon", retry_after_seconds: seconds})

      {:error, :not_pending} ->
        not_pending(conn)

      {:error, reason} ->
        verification_unavailable(conn, reason)
    end
  end

  def login(conn, %{"email" => email, "password" => password}) do
    user_agent = get_req_header(conn, "user-agent") |> List.first()

    case Auth.login(email, password, user_agent) do
      {:ok, auth} ->
        config = RuntimeConfig.auth!()
        session = auth.session

        conn
        |> delete_verification_cookie()
        |> put_resp_cookie(config.cookie_name, auth.raw_token, cookie_options(config))
        |> json(%{
          user: auth.user,
          session_id: session["session_id"],
          expires_at: session["expires_at"],
          csrf_token: auth.csrf_token
        })

      # Only the right password reaches this branch, so the timed step resumes
      # for the account's owner without revealing whether other addresses exist.
      {:error, {:email_not_verified, verification}} ->
        conn
        |> put_verification_cookie(verification.user_id)
        |> put_status(:forbidden)
        |> json(%{
          error: "email_not_verified",
          resend_after_seconds: verification.resend_after_seconds,
          email_hint: verification.email_hint
        })

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
        case Auth.end_session(ctx.user["user_id"], ctx.session["session_id"]) do
          :ok ->
            config = RuntimeConfig.auth!()

            conn
            |> delete_resp_cookie(config.cookie_name, path: "/")
            |> json(%{status: "logged_out"})

          # The session may still be valid on the server. The cookie stays, so
          # this browser can retry; clearing it would only hide a live session.
          {:error, reason} ->
            Logger.error(
              "logout could not end session_id=#{ctx.session["session_id"]}: " <>
                inspect(reason, limit: 20)
            )

            conn
            |> put_resp_header("retry-after", "2")
            |> PublicError.render(
              :service_unavailable,
              "logout_unconfirmed",
              "The session could not be ended on the server. Try signing out again.",
              retryable: true
            )
        end

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

  # The pending account's id travels encrypted (unreadable and tamper-evident),
  # is sent only to the auth routes and expires with the verification link.
  defp verification_cookie(config), do: config.cookie_name <> "_verification"

  defp verification_cookie_options(config) do
    [
      http_only: true,
      secure: config.cookie_secure,
      same_site: config.cookie_same_site,
      path: "/api/v1/auth"
    ]
  end

  defp put_verification_cookie(conn, user_id) do
    config = RuntimeConfig.auth!()

    put_resp_cookie(
      conn,
      verification_cookie(config),
      %{"user_id" => user_id},
      [encrypt: true, max_age: config.verification_ttl_seconds] ++
        verification_cookie_options(config)
    )
  end

  defp delete_verification_cookie(conn) do
    config = RuntimeConfig.auth!()
    delete_resp_cookie(conn, verification_cookie(config), verification_cookie_options(config))
  end

  defp verification_owner(conn) do
    name = verification_cookie(RuntimeConfig.auth!())

    case fetch_cookies(conn, encrypted: [name]).cookies[name] do
      %{"user_id" => user_id} when is_binary(user_id) and user_id != "" -> {:ok, user_id}
      _ -> {:error, :not_pending}
    end
  end

  defp not_pending(conn) do
    conn
    |> delete_verification_cookie()
    |> PublicError.render(
      :not_found,
      "verification_not_pending",
      "No account is waiting for verification in this browser. Sign in to continue."
    )
  end

  defp verification_unavailable(conn, reason) do
    Logger.error("verification step unavailable: " <> inspect(reason, limit: 20))

    conn
    |> put_resp_header("retry-after", "2")
    |> PublicError.render(
      :service_unavailable,
      "verification_unavailable",
      "The verification step could not be checked right now. Try again.",
      retryable: true
    )
  end

  defp mail_delivery({:ok, _}), do: "sent"
  defp mail_delivery({:error, _}), do: "failed"

  defp accepted(conn), do: conn |> put_status(:accepted) |> json(%{status: "accepted"})
  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
