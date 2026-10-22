defmodule ItsmBackend.Mail do
  @moduledoc """
  Provider-neutral outbound mail boundary.

  Supported transports:
    * `local` - Swoosh in-process mailbox for development.
    * `brevo_api` - Brevo transactional HTTPS API using a static API key.
    * `gmail_api` - legacy Gmail REST API transport retained as fallback.

  Recipients at the local mailbox lab domain are delivered through the lab's
  SMTP service (see `ItsmBackend.Mail.LabRelay`) whatever the mode.

  A successful delivery returns `%{transport: mode, message_id: id | nil}`:
  the transport that accepted the message and the provider's own message id,
  when that transport returns one. Acceptance is not inbox delivery; the id
  lets an operator reconcile the final outcome in the provider's event log.
  """

  import Swoosh.Email

  alias ItsmBackend.GmailOAuth
  alias ItsmBackend.Mail.Brevo
  alias ItsmBackend.Mail.LabRelay
  alias ItsmBackend.Mailer
  alias ItsmBackend.RuntimeConfig

  @spec deliver_text(String.t() | {String.t(), String.t()}, String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_text(to, subject, text_body)
      when is_binary(subject) and is_binary(text_body) do
    config = RuntimeConfig.auth!()

    deliver_message(
      to,
      subject,
      text_body,
      nil,
      {config.mail_from_name, config.mail_from_email},
      outbound_mode()
    )
  end

  @spec deliver_multipart(
          String.t() | {String.t(), String.t()},
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, term()} | {:error, term()}
  def deliver_multipart(to, subject, text_body, html_body)
      when is_binary(subject) and is_binary(text_body) and is_binary(html_body) do
    config = RuntimeConfig.auth!()

    deliver_message(
      to,
      subject,
      text_body,
      html_body,
      {config.mail_from_name, config.mail_from_email},
      outbound_mode()
    )
  end

  defp deliver_message(to, subject, text_body, html_body, {from_name, _from_email} = from, mode) do
    if LabRelay.handles?(to) do
      to
      |> LabRelay.deliver(subject, text_body, html_body, from_name)
      |> receipt("lab_smtp")
    else
      to
      |> deliver_provider(subject, text_body, html_body, from, mode)
      |> receipt(mode)
    end
  end

  # Only an identifier the transport actually returned is kept; none is invented.
  defp receipt({:ok, %{message_id: id}}, transport) when is_binary(id),
    do: {:ok, %{transport: transport, message_id: id}}

  defp receipt({:ok, %{id: id}}, transport) when is_binary(id),
    do: {:ok, %{transport: transport, message_id: id}}

  defp receipt({:ok, _accepted}, transport), do: {:ok, %{transport: transport, message_id: nil}}
  defp receipt({:error, _reason} = error, _transport), do: error

  defp deliver_provider(to, subject, text_body, html_body, from, "brevo_api") do
    Brevo.deliver(to, subject, text_body, html_body, from)
  end

  defp deliver_provider(to, subject_value, text_body_value, html_body_value, from_value, mode) do
    email =
      new()
      |> to(to)
      |> from(from_value)
      |> subject(subject_value)
      |> text_body(text_body_value)
      |> maybe_html_body(html_body_value)

    deliver_swoosh(email, mode)
  end

  defp maybe_html_body(email, value) when is_binary(value) do
    case String.trim(value) do
      "" -> email
      html -> html_body(email, html)
    end
  end

  defp maybe_html_body(email, _value), do: email

  defp deliver_swoosh(email, "gmail_api") do
    with {:ok, access_token} <- GmailOAuth.access_token() do
      Mailer.deliver(email, access_token: access_token)
    end
  end

  defp deliver_swoosh(email, "local"), do: Mailer.deliver(email)
  defp deliver_swoosh(_email, mode), do: {:error, {:unsupported_mailer_mode, mode}}

  defp outbound_mode do
    :itsm_backend
    |> Application.get_env(:outbound_mail, [])
    |> Keyword.get(:mode, "local")
  end
end
