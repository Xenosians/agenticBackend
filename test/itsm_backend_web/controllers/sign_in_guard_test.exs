defmodule ItsmBackendWeb.SignInGuardTest do
  @moduledoc """
  Repeated wrong passwords and repeated reset requests are slowed down.

  Failures are counted per account and per client address. Once either reaches
  its limit inside the window, sign-in is refused with 429 and the seconds left,
  before any password is checked, so guessing stays slow even with the right
  password in the list. A successful sign-in clears the account's count. Reset
  requests stay silent about whether an account exists but stop sending mail
  once a client exceeds its limit. API responses carry no-store and nosniff.
  """
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.Auth
  alias ItsmBackend.Auth.SignInGuard
  alias ItsmBackend.RuntimeConfig

  @limits [
    account_failures: 3,
    address_failures: 6,
    reset_requests: 2,
    window_seconds: 300
  ]

  setup do
    original = Application.fetch_env!(:itsm_backend, :sign_in_guard)
    Application.put_env(:itsm_backend, :sign_in_guard, @limits)
    SignInGuard.reset()

    on_exit(fn ->
      Application.put_env(:itsm_backend, :sign_in_guard, original)
      SignInGuard.reset()
    end)

    :ok
  end

  defp active_account do
    suffix = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)
    email = "guard-#{suffix}@example.test"
    password = "correct horse battery #{suffix}!"

    {:ok, _user, token, _verification} =
      Auth.register(%{
        "email" => email,
        "display_name" => "Guard #{suffix}",
        "password" => password
      })

    {:ok, _} = Auth.verify_email(token)
    %{email: email, password: password}
  end

  defp sign_in(email, password, address \\ {10, 0, 0, 1}) do
    %{build_conn() | remote_ip: address}
    |> post(~p"/api/v1/auth/login", %{"email" => email, "password" => password})
  end

  test "an account is locked after repeated wrong passwords, even for the right one" do
    account = active_account()

    for _ <- 1..3 do
      assert json_response(sign_in(account.email, "wrong password guess"), 401)["error"] ==
               "invalid_credentials"
    end

    refused = sign_in(account.email, account.password)
    body = json_response(refused, 429)
    assert body["error"] == "sign_in_rate_limited"
    assert body["retry_after_seconds"] in 1..300
    assert [retry_after] = get_resp_header(refused, "retry-after")
    assert String.to_integer(retry_after) == body["retry_after_seconds"]
    refute Map.has_key?(refused.resp_cookies, RuntimeConfig.auth!().cookie_name)
  end

  test "a lock never reveals whether the address belongs to an account" do
    for _ <- 1..3 do
      assert json_response(sign_in("nobody-here@example.test", "wrong password guess"), 401)
    end

    assert json_response(sign_in("nobody-here@example.test", "wrong password guess"), 429)[
             "error"
           ] ==
             "sign_in_rate_limited"
  end

  test "one client guessing across many accounts is slowed down" do
    for index <- 1..6 do
      assert json_response(sign_in("spray-#{index}@example.test", "wrong password guess"), 401)
    end

    assert json_response(sign_in("spray-7@example.test", "wrong password guess"), 429)
    # Another client can still sign in to an untouched account.
    account = active_account()
    assert json_response(sign_in(account.email, account.password, {10, 0, 0, 2}), 200)
  end

  test "a successful sign-in clears the account's failures" do
    account = active_account()

    for _ <- 1..2, do: assert(json_response(sign_in(account.email, "wrong password guess"), 401))
    assert json_response(sign_in(account.email, account.password), 200)

    for _ <- 1..2, do: assert(json_response(sign_in(account.email, "wrong password guess"), 401))
    assert json_response(sign_in(account.email, account.password), 200)
  end

  test "the lock ends when the window passes" do
    account = active_account()
    for _ <- 1..3, do: sign_in(account.email, "wrong password guess")
    assert json_response(sign_in(account.email, account.password), 429)

    SignInGuard.age(300)

    assert json_response(sign_in(account.email, account.password), 200)
  end

  test "repeated reset requests stay silent but stop sending mail" do
    account = active_account()

    for _ <- 1..2 do
      conn = %{build_conn() | remote_ip: {10, 0, 0, 3}}
      conn = post(conn, ~p"/api/v1/auth/forgot-password", %{"email" => account.email})
      assert json_response(conn, 202)["status"] == "accepted"
      assert_received {:email, %Swoosh.Email{subject: "Reset your " <> _}}
    end

    conn = %{build_conn() | remote_ip: {10, 0, 0, 3}}
    conn = post(conn, ~p"/api/v1/auth/forgot-password", %{"email" => account.email})
    assert json_response(conn, 202)["status"] == "accepted"
    refute_received {:email, _}
  end

  test "API responses are never cached and never sniffed" do
    conn = get(build_conn(), ~p"/api/health")

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
  end
end
