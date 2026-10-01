defmodule Mix.Tasks.Itsm.Sdlc.WeeklyDigest do
  use Mix.Task

  @shortdoc "Sends the weekly SDLC digest through the Gmail OAuth mail boundary"

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    start_mail_dependencies!()

    {opts, _rest, invalid} =
      OptionParser.parse(
        args,
        strict: [
          digest: :string,
          html_digest: :string,
          recipients: :string,
          subject: :string,
          dry_run: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("invalid arguments: #{inspect(invalid)}")
    end

    digest_path =
      opts[:digest] ||
        Mix.raise("--digest PATH is required")

    html_digest_path =
      opts[:html_digest] ||
        Mix.raise("--html-digest PATH is required")

    recipients_path =
      opts[:recipients] ||
        Mix.raise("--recipients PATH is required")

    digest =
      digest_path
      |> Path.expand()
      |> File.read!()

    html_digest =
      html_digest_path
      |> Path.expand()
      |> File.read!()

    recipients =
      recipients_path
      |> Path.expand()
      |> File.read!()
      |> Jason.decode!()
      |> Map.get(
        "recipients",
        []
      )
      |> normalize_recipients!()

    if recipients == [] do
      Mix.raise("no enabled recipients are configured")
    end

    subject =
      opts[:subject] ||
        "Agentic ITSM Weekly SDLC Update — #{Date.utc_today()}"

    Mix.shell().info("Agentic ITSM Weekly SDLC Digest")

    Mix.shell().info("================================")

    Mix.shell().info("text digest: #{Path.expand(digest_path)}")

    Mix.shell().info("html digest: #{Path.expand(html_digest_path)}")

    Mix.shell().info("recipients: #{length(recipients)}")

    Mix.shell().info("subject: #{subject}")

    if opts[:dry_run] do
      Enum.each(
        recipients,
        fn recipient ->
          Mix.shell().info(
            "DRY RUN: #{recipient.name} <#{recipient.email}> " <>
              "(#{recipient.role})"
          )
        end
      )

      Mix.shell().info("format: multipart text/plain + text/html")

      Mix.shell().info("No email was sent.")

      :ok
    else
      ensure_gmail_api!()

      results =
        Enum.map(
          recipients,
          fn recipient ->
            delivery =
              ItsmBackend.Mail.deliver_multipart(
                {
                  recipient.name,
                  recipient.email
                },
                subject,
                digest,
                html_digest
              )

            case delivery do
              {:ok, _metadata} ->
                Mix.shell().info("sent: #{recipient.name} <#{recipient.email}>")

                {:ok, recipient.email}

              {:error, reason} ->
                Mix.shell().error(
                  "failed: #{recipient.email}: " <>
                    sanitize_reason(reason)
                )

                {:error, recipient.email}
            end
          end
        )

      failures =
        Enum.filter(
          results,
          &match?(
            {:error, _},
            &1
          )
        )

      if failures != [] do
        Mix.raise(
          "weekly digest had " <>
            "#{length(failures)} failed delivery/deliveries"
        )
      end

      Mix.shell().info("Weekly digest delivery: PASS")

      :ok
    end
  end

  defp normalize_recipients!(values)
       when is_list(values) do
    values
    |> Enum.filter(fn item ->
      is_map(item) and
        Map.get(
          item,
          "enabled"
        ) == true
    end)
    |> Enum.map(fn item ->
      role =
        item
        |> Map.get(
          "role",
          "stakeholder"
        )
        |> normalize_non_empty!("role")

      email =
        item
        |> Map.get("email")
        |> normalize_non_empty!("email")

      unless String.contains?(
               email,
               "@"
             ) do
        Mix.raise("invalid recipient email for role #{role}")
      end

      name =
        case Map.get(
               item,
               "name"
             ) do
          value
          when is_binary(value) ->
            case String.trim(value) do
              "" ->
                email

              normalized ->
                normalized
            end

          _ ->
            email
        end

      %{
        role: role,
        name: name,
        email: email
      }
    end)
  end

  defp normalize_recipients!(_value) do
    Mix.raise("recipients JSON must contain a recipients array")
  end

  defp normalize_non_empty!(
         value,
         field
       )
       when is_binary(value) do
    normalized =
      String.trim(value)

    if normalized == "" do
      Mix.raise("recipient #{field} must not be blank")
    end

    normalized
  end

  defp normalize_non_empty!(
         _value,
         field
       ) do
    Mix.raise("recipient #{field} must be a string")
  end

  defp ensure_gmail_api! do
    mode =
      :itsm_backend
      |> Application.get_env(
        :outbound_mail,
        []
      )
      |> Keyword.get(
        :mode,
        "local"
      )

    if mode != "gmail_api" do
      Mix.raise(
        "real weekly delivery requires MAILER_MODE=gmail_api; " <>
          "use --dry-run while mail is not configured"
      )
    end
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
