defmodule ItsmBackend.Mail.LabRelayTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Mail.LabRelay

  setup do
    originals =
      Map.new([:lab_mail, :mailbox_lab_domain], fn key ->
        {key, Application.get_env(:itsm_backend, key)}
      end)

    Application.put_env(:itsm_backend, :mailbox_lab_domain, "itsm.test")

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

  test "routes only lab-domain recipients" do
    assert LabRelay.handles?("alice@itsm.test")
    assert LabRelay.handles?({"Alice", "Alice@ITSM.test"})
    refute LabRelay.handles?("alice@example.com")
    refute LabRelay.handles?("alice@itsm.test.example.com")
    refute LabRelay.handles?("@itsm.test")
  end

  test "is disabled without a lab sender credential or outside the lab domain" do
    Application.put_env(:itsm_backend, :lab_mail,
      enabled: true,
      sender: "notifications@itsm.test",
      password: nil
    )

    refute LabRelay.handles?("alice@itsm.test")

    Application.put_env(:itsm_backend, :lab_mail,
      enabled: true,
      sender: "notifications@example.com",
      password: "lab-sender-secret-value"
    )

    refute LabRelay.handles?("alice@itsm.test")

    Application.put_env(:itsm_backend, :lab_mail,
      enabled: false,
      sender: "n@itsm.test",
      password: "x"
    )

    refute LabRelay.handles?("alice@itsm.test")
  end

  test "an unreachable lab server is an error, never a silent success" do
    assert {:error, _reason} = LabRelay.deliver("alice@itsm.test", "Subject", "Body", nil, "ITSM")
  end
end
