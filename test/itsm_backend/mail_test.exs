defmodule ItsmBackend.MailTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Mail

  @settings [:outbound_mail, :brevo_api, :lab_mail]

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
             Mail.deliver_text("recipient@example.test", "Subject", "Body")
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
             Mail.deliver_text("recipient@example.test", "Subject", "Body")
  end
end
