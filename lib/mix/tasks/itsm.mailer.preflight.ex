defmodule Mix.Tasks.Itsm.Mailer.Preflight do
  use Mix.Task

  @shortdoc "Checks outbound mail config and optionally sends an isolated test email"
  @requirements ["compile"]

  @impl Mix.Task
  def run(args) do
    start_mail_dependencies!()

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [to: :string],
        aliases: [t: :to]
      )

    if invalid != [] do
      Mix.raise("invalid arguments: #{inspect(invalid)}")
    end

    mail_config = Application.get_env(:itsm_backend, ItsmBackend.Mailer, [])
    transport = Application.get_env(:itsm_backend, :outbound_mail, [])
    adapter = Keyword.get(mail_config, :adapter)
    mode = Keyword.get(transport, :mode, "unknown")

    Mix.shell().info("ITSM Mailer Preflight")
    Mix.shell().info("====================")
    Mix.shell().info("mode: #{mode}")
    Mix.shell().info("adapter: #{inspect(adapter)}")

    relay = Keyword.get(mail_config, :relay)
    port = Keyword.get(mail_config, :port)
    tls = Keyword.get(mail_config, :tls)
    ssl = Keyword.get(mail_config, :ssl)
    auth = Keyword.get(mail_config, :auth)

    if relay, do: Mix.shell().info("relay: #{relay}")
    if port, do: Mix.shell().info("port: #{port}")
    if tls, do: Mix.shell().info("tls: #{inspect(tls)}")
    unless is_nil(ssl), do: Mix.shell().info("ssl: #{inspect(ssl)}")
    if auth, do: Mix.shell().info("auth: #{inspect(auth)}")

    case opts[:to] do
      nil ->
        Mix.shell().info("config: OK")
        Mix.shell().info("Pass --to you@example.com to send a real isolated SMTP test.")
        Mix.shell().info("The Phoenix supervision tree / AI queue worker is NOT started by this task.")

      recipient ->
        send_test(recipient, mode)
    end
  end

  defp start_mail_dependencies! do
    [:crypto, :asn1, :public_key, :ssl, :gen_smtp, :swoosh]
    |> Enum.each(fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} ->
          :ok

        {:error, reason} ->
          Mix.raise("failed to start mail dependency #{inspect(app)}: #{inspect(reason)}")
      end
    end)
  end

  defp send_test(_recipient, "local") do
    Mix.raise(
      "MAILER_MODE=local uses in-process memory. Test through the running Phoenix app " <>
        "and inspect http://127.0.0.1:4000/dev/mailbox instead."
    )
  end

  defp send_test(recipient, _mode) do
    subject = "Agentic ITSM mailer preflight"

    body =
      "This is an isolated outbound-mail preflight from Agentic ITSM.\n\n" <>
        "The Phoenix supervision tree and AI worker were not started for this test.\n\n" <>
        "If you received this message, the configured SMTP transport is working."

    case ItsmBackend.Mail.deliver_text(recipient, subject, body) do
      {:ok, metadata} ->
        Mix.shell().info("delivery: OK")
        Mix.shell().info("provider response: #{inspect(metadata)}")

      {:error, reason} ->
        Mix.raise("delivery failed: #{sanitize_reason(reason)}")
    end
  end

  defp sanitize_reason(reason) do
    rendered = inspect(reason, pretty: true, limit: :infinity, printable_limit: :infinity)

    case System.get_env("SMTP_PASSWORD") do
      secret when is_binary(secret) and byte_size(secret) > 0 ->
        String.replace(rendered, secret, "[REDACTED]")

      _ ->
        rendered
    end
  end
end
