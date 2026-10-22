defmodule ItsmBackend.MailTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Mail

  @settings [:outbound_mail, :brevo_api, :lab_mail, :mailbox_lab_domain]

  setup context do
    originals = Map.new(@settings, fn key -> {key, Application.get_env(:itsm_backend, key)} end)
    previous_options = Req.default_options()
    Req.Test.set_req_test_from_context(context)
    Req.Test.verify_on_exit!(context)
    Req.default_options(Keyword.put(previous_options, :plug, {Req.Test, __MODULE__}))
    # Recipients below are outside any lab domain, so the configured provider is used.
    Application.delete_env(:itsm_backend, :lab_mail)

    on_exit(fn ->
      Req.default_options(previous_options)

      Enum.each(originals, fn
        {key, nil} -> Application.delete_env(:itsm_backend, key)
        {key, value} -> Application.put_env(:itsm_backend, key, value)
      end)
    end)

    :ok
  end

  test "provider acceptance names the transport and the provider's message id" do
    Application.put_env(:itsm_backend, :outbound_mail, mode: "brevo_api")
    Application.put_env(:itsm_backend, :brevo_api, api_key: "test-brevo-key")

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(Plug.Conn.put_status(conn, 201), %{
        "messageId" => "<provider-message-1@relay.test>"
      })
    end)

    assert {:ok, %{transport: "brevo_api", message_id: "<provider-message-1@relay.test>"}} =
             Mail.deliver_text("recipient@example.com", "Subject", "Body")
  end

  test "public transports reject reserved recipients before OAuth or email dispatch" do
    for mode <- ["brevo_api", "gmail_api"],
        recipient <- [
          "person@example.test",
          "person@example.invalid",
          "person@itsm.test",
          {"Person", "person@TEST."}
        ] do
      Application.put_env(:itsm_backend, :outbound_mail, mode: mode)

      assert {:error, :invalid_mail_recipient} =
               Mail.deliver_text(recipient, "Subject", "Body")

      assert {:error, :invalid_mail_recipient} =
               Mail.deliver_multipart(recipient, "Subject", "Body", "<p>Body</p>")
    end
  end

  test "a configured lab recipient still uses its internal SMTP route" do
    Application.put_env(:itsm_backend, :outbound_mail, mode: "brevo_api")
    Application.put_env(:itsm_backend, :mailbox_lab_domain, "itsm.test")

    Application.put_env(:itsm_backend, :lab_mail,
      enabled: true,
      sender: "notifications@itsm.test",
      password: "isolated-lab-fixture-password",
      host: "127.0.0.1",
      port: 1
    )

    # The closed loopback port produces an actual SMTP connection failure,
    # proving this was routed internally rather than rejected or sent publicly.
    assert {:error, {:retries_exceeded, _reason}} =
             Mail.deliver_text("person@itsm.test", "Subject", "Body")
  end

  test "an invalid Brevo acceptance receipt remains an error at the mail boundary" do
    Application.put_env(:itsm_backend, :outbound_mail, mode: "brevo_api")
    Application.put_env(:itsm_backend, :brevo_api, api_key: "test-brevo-key")

    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(Plug.Conn.put_status(conn, 201), %{}) end)

    assert {:error, {:brevo_invalid_acceptance_receipt, 201}} =
             Mail.deliver_text("recipient@example.com", "Subject", "Body")
  end

  test "a transport without a message id reports acceptance without inventing one" do
    Application.put_env(:itsm_backend, :outbound_mail, mode: "local")

    assert {:ok, %{transport: "local", message_id: nil}} =
             Mail.deliver_text("recipient@example.test", "Subject", "Body")
  end

  test "a provider rejection is returned unchanged" do
    Application.put_env(:itsm_backend, :outbound_mail, mode: "brevo_api")
    Application.put_env(:itsm_backend, :brevo_api, api_key: "test-brevo-key")

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(Plug.Conn.put_status(conn, 401), %{"code" => "unauthorized"})
    end)

    assert {:error, {:brevo_delivery_rejected, 401, %{"code" => "unauthorized"}}} =
             Mail.deliver_text("recipient@example.com", "Subject", "Body")
  end
end
