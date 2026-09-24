defmodule Mix.Tasks.Itsm.Mailer.Preflight do
  use Mix.Task

  @shortdoc "Checks outbound mail config and optionally sends an isolated test email"

  # app.config is important here because config/runtime.exs must be
  # evaluated before we inspect the configured transport.
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    start_mail_dependencies!()

    {opts, _rest, invalid} =
      OptionParser.parse(
        args,
        strict: [
          to: :string
        ],
        aliases: [
          t: :to
        ]
      )

    if invalid != [] do
      Mix.raise("invalid arguments: #{inspect(invalid)}")
    end

    mail_config =
      Application.get_env(
        :itsm_backend,
        ItsmBackend.Mailer,
        []
      )

    transport =
      Application.get_env(
        :itsm_backend,
        :outbound_mail,
        []
      )

    adapter =
      Keyword.get(
        mail_config,
        :adapter
      )

    mode =
      Keyword.get(
        transport,
        :mode,
        "unknown"
      )

    Mix.shell().info("ITSM Mailer Preflight")

    Mix.shell().info("====================")

    Mix.shell().info("mode: #{mode}")

    Mix.shell().info("adapter: #{inspect(adapter)}")

    describe_transport(mode)

    case opts[:to] do
      nil ->
        Mix.shell().info("config: OK")

        Mix.shell().info("Pass --to you@example.com to send a real isolated delivery test.")

        Mix.shell().info(
          "The Phoenix supervision tree / AI queue worker is NOT started by this task."
        )

      recipient ->
        send_test(
          recipient,
          mode
        )
    end
  end

  defp describe_transport("gmail_api") do
    Mix.shell().info("transport: Gmail REST API")

    Mix.shell().info("authentication: OAuth2 refresh token")
  end

  defp describe_transport("local") do
    Mix.shell().info("transport: local Swoosh mailbox")
  end

  defp describe_transport(_mode) do
    :ok
  end

  defp start_mail_dependencies! do
    [
      :crypto,
      :ssl,
      :req,
      :swoosh
    ]
    |> Enum.each(fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} ->
          :ok

        {:error, reason} ->
          Mix.raise(
            "failed to start mail dependency " <>
              "#{inspect(app)}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp send_test(
         _recipient,
         "local"
       ) do
    Mix.raise(
      "MAILER_MODE=local uses in-process memory. " <>
        "Test through the running Phoenix app and inspect " <>
        "http://127.0.0.1:4000/dev/mailbox instead."
    )
  end

  defp send_test(
         recipient,
         _mode
       ) do
    subject =
      "Agentic ITSM mailer preflight"

    body =
      "This is an isolated outbound-mail preflight from Agentic ITSM.\n\n" <>
        "The Phoenix supervision tree and AI worker were not started " <>
        "for this test.\n\n" <>
        "If you received this message, the configured Gmail API " <>
        "transport is working."

    case ItsmBackend.Mail.deliver_text(
           recipient,
           subject,
           body
         ) do
      {:ok, metadata} ->
        Mix.shell().info("delivery: OK")

        Mix.shell().info("provider response: #{inspect(metadata)}")

      {:error, reason} ->
        Mix.raise("delivery failed: #{sanitize_reason(reason)}")
    end
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
      "GMAIL_CLIENT_SECRET",
      "GMAIL_REFRESH_TOKEN"
    ]
    |> Enum.reduce(
      rendered,
      fn variable, accumulator ->
        case System.get_env(variable) do
          secret
          when is_binary(secret) and
                 byte_size(secret) > 0 ->
            String.replace(
              accumulator,
              secret,
              "[REDACTED]"
            )

          _ ->
            accumulator
        end
      end
    )
  end
end
