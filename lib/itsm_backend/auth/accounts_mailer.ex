defmodule ItsmBackend.Auth.AccountsMailer do
  @moduledoc false

  alias ItsmBackend.Mail
  alias ItsmBackend.RuntimeConfig

  def deliver_verification(user, token) do
    config = RuntimeConfig.auth!()
    url = config.frontend_base_url <> "/?verify_token=" <> URI.encode_www_form(token)

    Mail.deliver_text(
      {user["display_name"], user["email"]},
      "Verify your Agentic ITSM account",
      "Verify your account using this link:\n\n#{url}\n\nThis link expires automatically."
    )
  end

  def deliver_password_reset(user, token) do
    config = RuntimeConfig.auth!()
    url = config.frontend_base_url <> "/?reset_token=" <> URI.encode_www_form(token)

    Mail.deliver_text(
      {user["display_name"], user["email"]},
      "Reset your Agentic ITSM password",
      "Reset your password using this link:\n\n#{url}\n\nIf you did not request this, ignore this email."
    )
  end
end
