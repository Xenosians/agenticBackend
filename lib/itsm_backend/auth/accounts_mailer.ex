defmodule ItsmBackend.Auth.AccountsMailer do
  @moduledoc """
  Sends account mail (verification and password reset) synchronously.

  Callers report only whether the mail was sent, so a refusal is logged here
  with its transport and failure class. The log never carries the recipient,
  the link or its token.
  """

  require Logger

  alias ItsmBackend.Mail
  alias ItsmBackend.Mail.LabRelay
  alias ItsmBackend.RuntimeConfig

  def deliver_verification(user, token) do
    config = RuntimeConfig.auth!()
    url = config.frontend_base_url <> "/?verify_token=" <> URI.encode_www_form(token)
    to = {user["display_name"], user["email"]}

    to
    |> Mail.deliver_text(
      "Verify your #{config.mail_from_name} account",
      "Verify your account using this link:\n\n#{url}\n\nThis link expires automatically."
    )
    |> report("verification", to)
  end

  def deliver_password_reset(user, token) do
    config = RuntimeConfig.auth!()
    url = config.frontend_base_url <> "/?reset_token=" <> URI.encode_www_form(token)
    to = {user["display_name"], user["email"]}

    to
    |> Mail.deliver_text(
      "Reset your #{config.mail_from_name} password",
      "Reset your password using this link:\n\n#{url}\n\nIf you did not request this, ignore this email."
    )
    |> report("password_reset", to)
  end

  defp report({:ok, _receipt} = sent, _kind, _to), do: sent

  defp report({:error, reason} = failed, kind, to) do
    Logger.warning(
      "account mail not sent kind=#{kind} transport=#{transport(to)} reason=#{failure_class(reason)}"
    )

    failed
  end

  defp transport(to), do: if(LabRelay.handles?(to), do: "lab_smtp", else: "provider")

  # Only the atoms of a transport error are logged, outermost first (for SMTP
  # e.g. retries_exceeded.network_failure.error.econnrefused). Provider and
  # SMTP reply text may echo the recipient, so strings are never written.
  defp failure_class(reason) do
    case reason |> atoms() |> Enum.reject(&(&1 in [nil, true, false])) do
      [] -> "unclassified"
      classes -> Enum.map_join(classes, ".", &Atom.to_string/1)
    end
  end

  defp atoms(reason) when is_atom(reason), do: [reason]

  defp atoms(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.flat_map(&atoms/1)

  defp atoms(_reason), do: []
end
