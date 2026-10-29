defmodule ItsmBackendWeb.AuthVerificationTest do
  @moduledoc """
  Email verification is a timed step of registration. The browser holds only an
  encrypted HttpOnly cookie binding it to the pending account; the server keeps
  the wait between verification emails.
  """
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.Auth
  alias ItsmBackend.RuntimeConfig
  alias ItsmBackend.Surreal

  defp config, do: RuntimeConfig.auth!()
  defp cookie_name, do: config().cookie_name <> "_verification"
  defp first_wait, do: config().verification_resend_seconds

  defp registration do
    suffix = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)

    %{
      "email" => "verify-#{suffix}@example.test",
      "display_name" => "Verify #{suffix}",
      "password" => "correct horse battery #{suffix}!"
    }
  end

  defp register(params) do
    conn = post(build_conn(), ~p"/api/v1/auth/register", params)
    assert %{"verification_required" => true} = json_response(conn, 201)
    {conn, mailed_token()}
  end

  defp mailed_token do
    assert_received {:email, %Swoosh.Email{subject: "Verify your " <> _, text_body: body}}
    [_, token] = Regex.run(~r/verify_token=(\S+)/, body)
    URI.decode_www_form(token)
  end

  # The account's latest verification email was sent `seconds` ago.
  defp age_latest_mail(email, seconds) do
    {:ok, user} = Auth.find_user_by_email(email)
    sent_at = DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()

    {:ok, _} =
      Surreal.query(
        "UPDATE ONLY type::record($table, $id) SET verification_sent_at = $sent_at;",
        %{"table" => "app_user", "id" => user["user_id"], "sent_at" => Surreal.datetime(sent_at)}
      )
  end

  test "registration starts a timed verification held only in an encrypted HttpOnly cookie" do
    params = registration()
    {conn, _token} = register(params)
    body = json_response(conn, 201)

    assert body["resend_after_seconds"] in (first_wait() - 1)..first_wait()
    cookie = conn.resp_cookies[cookie_name()]
    assert cookie.http_only
    assert cookie.path == "/api/v1/auth"
    assert cookie.max_age == config().verification_ttl_seconds
    refute cookie.value =~ body["user"]["user_id"]
    refute cookie.value =~ params["email"]
  end

  test "a resend inside the wait is refused with the time left and sends nothing" do
    {conn, _token} = register(registration())

    resend = post(recycle(conn), ~p"/api/v1/auth/resend-verification", %{})

    body = json_response(resend, 429)
    assert body["error"] == "verification_resend_too_soon"
    assert body["retry_after_seconds"] in 1..first_wait()

    assert get_resp_header(resend, "retry-after") == [
             Integer.to_string(body["retry_after_seconds"])
           ]

    refute_received {:email, _}
  end

  test "after the wait a resend mails a working link and the next wait doubles" do
    params = registration()
    {conn, _first_token} = register(params)
    age_latest_mail(params["email"], first_wait() + 1)

    resend = post(recycle(conn), ~p"/api/v1/auth/resend-verification", %{})

    assert %{"status" => "sent", "mail_delivery" => "sent", "resend_after_seconds" => next} =
             json_response(resend, 202)

    assert next == min(2 * first_wait(), config().verification_resend_max_seconds)
    token = mailed_token()
    too_soon = post(recycle(resend), ~p"/api/v1/auth/resend-verification", %{})
    assert json_response(too_soon, 429)["retry_after_seconds"] in (next - 1)..next
    refute_received {:email, _}

    verified = post(recycle(resend), ~p"/api/v1/auth/verify-email", %{"token" => token})
    assert %{"verified" => true} = json_response(verified, 200)
    assert verified.resp_cookies[cookie_name()].max_age == 0
  end

  test "an unverified sign-in with the right password resumes the timed verification" do
    params = registration()
    register(params)

    wrong =
      post(build_conn(), ~p"/api/v1/auth/login", %{
        "email" => params["email"],
        "password" => "not the right password"
      })

    assert json_response(wrong, 401)["error"] == "invalid_credentials"
    refute Map.has_key?(wrong.resp_cookies, cookie_name())

    right = post(build_conn(), ~p"/api/v1/auth/login", Map.take(params, ["email", "password"]))
    body = json_response(right, 403)
    assert body["error"] == "email_not_verified"
    assert body["resend_after_seconds"] in 1..first_wait()
    assert right.resp_cookies[cookie_name()].http_only

    status = json_response(get(recycle(right), ~p"/api/v1/auth/verification"), 200)
    assert status["status"] == "pending"
    assert status["resend_after_seconds"] in 1..first_wait()
    assert String.ends_with?(status["email_hint"], "@example.test")
    refute status["email_hint"] == params["email"]
  end

  test "without this browser's verification cookie nothing is shown or sent" do
    params = registration()
    register(params)

    for conn <- [build_conn(), put_req_cookie(build_conn(), cookie_name(), "tampered")] do
      resend = post(conn, ~p"/api/v1/auth/resend-verification", %{"email" => params["email"]})
      assert json_response(resend, 404)["error"] == "verification_not_pending"

      assert json_response(get(conn, ~p"/api/v1/auth/verification"), 404)["error"] ==
               "verification_not_pending"
    end

    refute_received {:email, _}
  end

  test "a verification completed in another browser ends the pending step here" do
    {conn, token} = register(registration())

    assert %{"verified" => true} =
             json_response(
               post(build_conn(), ~p"/api/v1/auth/verify-email", %{"token" => token}),
               200
             )

    status = get(recycle(conn), ~p"/api/v1/auth/verification")
    assert json_response(status, 200) == %{"status" => "verified"}
    assert status.resp_cookies[cookie_name()].max_age == 0

    resend = post(recycle(conn), ~p"/api/v1/auth/resend-verification", %{})
    assert json_response(resend, 404)["error"] == "verification_not_pending"
    refute_received {:email, _}
  end
end
