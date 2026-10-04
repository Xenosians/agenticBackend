defmodule Mix.Tasks.Itsm.Mailer.Preflight do
  use Mix.Task

  @shortdoc "Checks outbound mail config and optionally sends one isolated test email"
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    start_mail_dependencies!()

    {opts, _rest, invalid} =
      OptionParser.parse(
        args,
        strict: [to: :string],
        aliases: [t: :to]
      )

    if invalid != [] do
      Mix.raise("invalid arguments: #{inspect(invalid)}")
    end

    transport = Application.get_env(:itsm_backend, :outbound_mail, [])
    mode = Keyword.get(transport, :mode, "unknown")

    Mix.shell().info("ITSM Mailer Preflight")
    Mix.shell().info("====================")
    Mix.shell().info("mode: #{mode}")
    describe_transport(mode)

    case opts[:to] do
      nil ->
        Mix.shell().info("config: OK")
        Mix.shell().info("Pass --to you@example.com to send a real isolated delivery test.")
        Mix.shell().info("The full Phoenix supervision tree is not started by this task.")

      recipient ->
        send_test(recipient, mode)
    end
  end

  defp describe_transport("brevo_api") do
    Mix.shell().info("transport: Brevo transactional HTTPS API")
    Mix.shell().info("authentication: static server-side API key")
    Mix.shell().info("smtp: not used")
    Mix.shell().info("oauth refresh token: not used")
  end

  defp describe_transport("gmail_api") do
    Mix.shell().info("transport: Gmail REST API (legacy fallback)")
    Mix.shell().info("authentication: OAuth2 refresh token")
  end

  defp describe_transport("local") do
    Mix.shell().info("transport: local Swoosh mailbox")
  end

  defp describe_transport(_mode), do: :ok

  defp send_test(_recipient, "local") do
    Mix.raise("MAILER_MODE=local does not perform external delivery.")
  end

  defp send_test(recipient, mode) do
    subject = "Agentic ITSM mailer preflight"

    body = """
    This is an isolated outbound-mail preflight from Agentic ITSM.

    Configured transport: #{mode}

    If you received this message, external mail delivery is working.

    No AI job or provider mutation was executed by this test.
    """

    case ItsmBackend.Mail.deliver_text(recipient, subject, body) do
      {:ok, metadata} ->
        Mix.shell().info("delivery: OK")
        Mix.shell().info("provider response: #{inspect(metadata)}")

      {:error, reason} ->
        Mix.raise("delivery failed: " <> sanitize_reason(reason))
    end
  end

  defp start_mail_dependencies! do
    [:crypto, :ssl, :req, :swoosh]
    |> Enum.each(fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} ->
          :ok

        {:error, reason} ->
          Mix.raise("failed to start mail dependency #{inspect(app)}: #{inspect(reason)}")
      end
    end)
  end

  defp sanitize_reason(reason) do
    rendered =
      inspect(
        reason,
        pretty: true,
        limit: :infinity,
        printable_limit: :infinity
      )

    [
      "BREVO_API_KEY",
      "GMAIL_CLIENT_SECRET",
      "GMAIL_REFRESH_TOKEN"
    ]
    |> Enum.reduce(rendered, fn variable, accumulator ->
      case System.get_env(variable) do
        secret when is_binary(secret) and byte_size(secret) > 0 ->
          String.replace(accumulator, secret, "[REDACTED]")

        _ ->
          accumulator
      end
    end)
  end
end
