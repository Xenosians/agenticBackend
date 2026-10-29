defmodule ItsmBackend.Auth.AccountsMailerTest do
  @moduledoc """
  Account mail is sent synchronously and its caller reports only sent/failed.
  A refusal must still leave an operator-readable reason in the log: the
  transport and the failure class, never the address, link or token.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ItsmBackend.Auth.AccountsMailer

  setup do
    originals =
      Map.new([:lab_mail, :mailbox_lab_domain], fn key ->
        {key, Application.get_env(:itsm_backend, key)}
      end)

    Application.put_env(:itsm_backend, :mailbox_lab_domain, "itsm.test")

    # Port 1 refuses connections, so the lab relay fails before any SMTP exchange.
    Application.put_env(:itsm_backend, :lab_mail,
      enabled: true,
      sender: "notifications@itsm.test",
      password: "lab-sender-secret-value",
      host: "127.0.0.1",
      port: 1
    )

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> Application.delete_env(:itsm_backend, key)
        {key, value} -> Application.put_env(:itsm_backend, key, value)
      end)
    end)

    :ok
  end

  test "a refused verification mail logs its transport and failure class only" do
    user = %{"display_name" => "Alice Example", "email" => "alice.example@itsm.test"}
    token = "verification-token-value"

    log =
      capture_log([level: :warning], fn ->
        assert {:error, _reason} = AccountsMailer.deliver_verification(user, token)
      end)

    assert log =~ "account mail not sent"
    assert log =~ "kind=verification"
    assert log =~ "transport=lab_smtp"
    # The nested failure class says why: here the relay refused the connection.
    assert log =~ ~r/reason=[a-z0-9_.]*econnrefused/
    refute log =~ "alice.example"
    refute log =~ token
    refute log =~ "lab-sender-secret-value"
  end
end
