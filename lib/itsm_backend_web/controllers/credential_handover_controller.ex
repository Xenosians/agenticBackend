defmodule ItsmBackendWeb.CredentialHandoverController do
  @moduledoc """
  Reveals the temporary password of an approved account, password reset or
  mailbox once, to the owner of that request, after the owner confirms their
  own Janus password. Wrong passwords count against the same limit as sign-in.
  """
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  request_contract(:reveal, required_body: ["password"], optional_body: [])

  require Logger

  alias ItsmBackend.Auth
  alias ItsmBackend.Auth.SignInGuard
  alias ItsmBackend.CredentialHandover
  alias ItsmBackendWeb.AuthRequest

  def reveal(conn, %{"job_id" => job_id, "credential_id" => credential_id}) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} -> confirm(conn, ctx.user, job_id, credential_id)
      {:error, conn} -> conn
    end
  end

  defp confirm(conn, user, job_id, credential_id) do
    case conn.body_params do
      %{"password" => password} when is_binary(password) and password != "" ->
        key = Auth.sign_in_key(user["email"])

        case SignInGuard.reserve_sign_in(key, conn.remote_ip) do
          :ok -> check_password(conn, key, user, password, job_id, credential_id)
          {:error, {:rate_limited, seconds}} -> rate_limited(conn, seconds)
        end

      _ ->
        error(conn, :unprocessable_entity, "invalid_request")
    end
  end

  defp check_password(conn, key, user, password, job_id, credential_id) do
    case Auth.confirm_password(user["user_id"], password) do
      :ok ->
        SignInGuard.record_success(key)
        handover(conn, user, job_id, credential_id)

      {:error, :invalid_credentials} ->
        SignInGuard.record_failure(key, conn.remote_ip)
        error(conn, :unauthorized, "invalid_credentials")

      {:error, _reason} ->
        error(conn, :unauthorized, "invalid_credentials")
    end
  end

  defp handover(conn, user, job_id, credential_id) do
    case CredentialHandover.reveal(user, job_id, credential_id) do
      {:ok, %{subject: subject, temporary_password: password}} ->
        Logger.info(
          "temporary credential revealed job_id=#{job_id} credential_id=#{credential_id} " <>
            "user_id=#{user["user_id"]}"
        )

        json(conn, %{
          credential_id: credential_id,
          subject: subject,
          temporary_password: password,
          must_change_at_first_sign_in: true
        })

      {:error, :not_found} ->
        error(conn, :not_found, "job_not_found")

      {:error, :forbidden} ->
        error(conn, :forbidden, "forbidden")

      {:error, :credential_not_found} ->
        error(conn, :not_found, "credential_not_found")

      {:error, :credential_already_revealed} ->
        error(conn, :gone, "credential_already_revealed")

      {:error, :credential_expired} ->
        error(conn, :gone, "credential_expired")

      {:error, :credential_unreadable} ->
        Logger.warning("temporary credential unreadable credential_id=#{credential_id}")
        error(conn, :conflict, "credential_unreadable")

      {:error, reason} ->
        Logger.error("temporary credential reveal failed: #{inspect(reason)}")
        error(conn, :service_unavailable, "credential_reveal_failed")
    end
  end

  defp rate_limited(conn, seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_status(:too_many_requests)
    |> json(%{
      error: "sign_in_rate_limited",
      message: "Too many password attempts. Wait before trying again.",
      retry_after_seconds: seconds
    })
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
