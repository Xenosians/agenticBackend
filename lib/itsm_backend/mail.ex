defmodule ItsmBackend.Mail do
  @moduledoc """
  Application-wide outbound mail boundary.

  Auth mail and future notification mail share the same configured
  Swoosh transport. The browser never receives SMTP credentials.
  """

  import Swoosh.Email

  alias ItsmBackend.Mailer
  alias ItsmBackend.RuntimeConfig

  @spec deliver_text(String.t() | {String.t(), String.t()}, String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_text(to, subject, text_body)
      when is_binary(subject) and is_binary(text_body) do
    config = RuntimeConfig.auth!()

    new()
    |> to(to)
    |> from({config.mail_from_name, config.mail_from_email})
    |> subject(subject)
    |> text_body(text_body)
    |> Mailer.deliver()
  end
end
