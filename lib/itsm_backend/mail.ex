defmodule ItsmBackend.Mail do
  @moduledoc """
  Application-wide outbound mail boundary.

  Auth mail and future notification mail share the same Swoosh
  message composition layer.

  Delivery is selected at runtime:

    * `local` uses the in-process Swoosh development mailbox.
    * `gmail_api` sends through Gmail's HTTPS API using OAuth2.

  Gmail OAuth credentials never reach the browser.
  """

  import Swoosh.Email

  alias ItsmBackend.GmailOAuth
  alias ItsmBackend.Mailer
  alias ItsmBackend.RuntimeConfig

  @spec deliver_text(
          String.t() | {String.t(), String.t()},
          String.t(),
          String.t()
        ) ::
          {:ok, term()} | {:error, term()}
  def deliver_text(
        to,
        subject,
        text_body
      )
      when is_binary(subject) and
             is_binary(text_body) do
    config =
      RuntimeConfig.auth!()

    email =
      new()
      |> to(to)
      |> from({
        config.mail_from_name,
        config.mail_from_email
      })
      |> subject(subject)
      |> text_body(text_body)

    deliver(
      email,
      outbound_mode()
    )
  end

  defp deliver(
         email,
         "gmail_api"
       ) do
    with {:ok, access_token} <-
           GmailOAuth.access_token() do
      Mailer.deliver(
        email,
        access_token: access_token
      )
    end
  end

  defp deliver(
         email,
         _mode
       ) do
    Mailer.deliver(email)
  end

  defp outbound_mode do
    :itsm_backend
    |> Application.get_env(
      :outbound_mail,
      []
    )
    |> Keyword.get(
      :mode,
      "local"
    )
  end
end
