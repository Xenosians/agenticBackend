defmodule ItsmBackend.MailOutboxTestTransport do
  @moduledoc false

  def deliver_text(_recipient, _subject, _body) do
    send(self(), :fixture_provider_received_message)

    case Process.get(:fixture_mail_result) do
      :raise -> raise "fixture transport failed after provider receipt"
      result -> result
    end
  end

  def deliver_multipart(recipient, subject, body, _html) do
    deliver_text(recipient, subject, body)
  end
end
