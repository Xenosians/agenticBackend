defmodule ItsmBackend.Mail.BrevoTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Mail.Brevo

  setup context do
    previous_options = Req.default_options()
    previous_config = Application.get_env(:itsm_backend, :brevo_api)
    Application.put_env(:itsm_backend, :brevo_api, api_key: "test-brevo-key")
    Req.Test.set_req_test_from_context(context)
    Req.Test.verify_on_exit!(context)

    # Even a deployment-wide retry setting must not cause an email resend.
    Req.default_options(
      previous_options
      |> Keyword.put(:plug, {Req.Test, __MODULE__})
      |> Keyword.put(:retry, :transient)
    )

    on_exit(fn ->
      Req.default_options(previous_options)

      if previous_config == nil do
        Application.delete_env(:itsm_backend, :brevo_api)
      else
        Application.put_env(:itsm_backend, :brevo_api, previous_config)
      end
    end)

    :ok
  end

  test "successful delivery preserves sender, multipart content and provider message id" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v3/smtp/email"
      assert Plug.Conn.get_req_header(conn, "api-key") == ["test-brevo-key"]

      assert conn.body_params == %{
               "sender" => %{"name" => "ITSM", "email" => "sender@example.test"},
               "to" => [%{"name" => "Test User", "email" => "recipient@example.test"}],
               "subject" => "Weekly progress",
               "textContent" => "Fixture report.",
               "htmlContent" => "<p>Fixture report.</p>"
             }

      Req.Test.json(conn |> Plug.Conn.put_status(201), %{"messageId" => "provider-message-1"})
    end)

    assert {:ok, %{provider: "brevo", status: 201, message_id: "provider-message-1"}} =
             Brevo.deliver(
               {"Test User", "Recipient@example.test"},
               "Weekly progress",
               "Fixture report.",
               "<p>Fixture report.</p>",
               {"ITSM", "Sender@example.test"}
             )
  end

  test "a connection lost after provider receipt makes one attempt and never resends" do
    caller = self()

    Req.Test.expect(__MODULE__, fn conn ->
      # Simulate a provider receiving the message before the acknowledgement
      # connection closes. Receipt alone cannot establish final delivery.
      send(caller, :provider_received_message)
      Req.Test.transport_error(conn, :closed)
    end)

    assert {:error, {:brevo_request_failed, %Req.TransportError{reason: :closed}}} = deliver()
    assert_receive :provider_received_message
    refute_received :provider_received_message
  end

  test "rate limits and server failures surface after a single request" do
    caller = self()

    for status <- [429, 500, 503] do
      Req.Test.expect(__MODULE__, fn conn ->
        send(caller, {:provider_attempt, status})
        Req.Test.json(conn |> Plug.Conn.put_status(status), %{"code" => "unavailable"})
      end)

      assert {:error, {:brevo_transient_error, ^status, %{"code" => "unavailable"}}} = deliver()
      assert_receive {:provider_attempt, ^status}
      refute_received {:provider_attempt, ^status}
    end
  end

  test "missing configuration and invalid addresses fail before sending" do
    assert {:error, :invalid_mail_address} =
             Brevo.deliver("invalid", "Subject", "Body", nil, {"ITSM", "sender@example.test"})

    Application.put_env(:itsm_backend, :brevo_api, api_key: " ")
    assert {:error, :missing_brevo_api_key} = deliver()
  end

  defp deliver do
    Brevo.deliver(
      "recipient@example.test",
      "Fixture report",
      "Fixture content",
      nil,
      {"ITSM", "sender@example.test"}
    )
  end
end
