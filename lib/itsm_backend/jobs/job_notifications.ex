defmodule ItsmBackend.Jobs.JobNotifications do
  @moduledoc """
  Deterministic AI-job email notifications.

  Notification content is derived only from durable job state and trusted
  backend metadata. No LLM-generated recommendation text is used.
  """

  require Logger

  alias ItsmBackend.Auth.SurrealStore, as: AuthStore
  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Mail.OutboxStore
  alias ItsmBackend.RuntimeConfig

  @notifiable_statuses [
    "waiting_approval",
    "completed",
    "failed"
  ]

  @spec enqueue_best_effort(Job.t()) :: :ok
  def enqueue_best_effort(%Job{} = job) do
    case enqueue(job) do
      {:ok, _value} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "job notification enqueue failed job_id=#{job.id}: " <>
            inspect(reason, limit: 20, printable_limit: 1_000)
        )

        :ok
    end
  end

  @spec enqueue(Job.t()) :: {:ok, term()} | {:error, term()}
  def enqueue(%Job{status: status} = job) when status in @notifiable_statuses do
    with {:ok, user} <- AuthStore.get_user(job.user_id),
         {:ok, recipient} <- recipient_from_user(user) do
      case recipient do
        :not_applicable ->
          {:ok, :not_applicable}

        %{name: name, email: email} ->
          {subject, text_body} = render(job)

          OutboxStore.enqueue(%{
            "dedupe_key" =>
              [
                "job",
                job.id,
                Integer.to_string(job.attempts),
                job.status
              ]
              |> Enum.join(":"),
            "kind" => "job_notification",
            "recipient_name" => name,
            "recipient_email" => email,
            "subject" => subject,
            "text_body" => text_body
          })
      end
    end
  end

  def enqueue(%Job{}), do: {:ok, :not_required}

  defp recipient_from_user(%{"email" => email} = user) when is_binary(email) do
    normalized = String.trim(email)

    if normalized == "" do
      {:ok, :not_applicable}
    else
      {:ok,
       %{
         email: normalized,
         name:
           user
           |> Map.get("display_name", normalized)
           |> normalize_name(normalized)
       }}
    end
  end

  defp recipient_from_user(nil), do: {:ok, :not_applicable}
  defp recipient_from_user(_user), do: {:error, :invalid_notification_user}

  defp render(%Job{} = job) do
    config = RuntimeConfig.auth!()

    subject =
      case job.status do
        "waiting_approval" -> "Agentic ITSM — approval required"
        "completed" -> "Agentic ITSM — request completed"
        "failed" -> "Agentic ITSM — request failed"
      end

    status_text =
      case job.status do
        "waiting_approval" -> "Your request is waiting for approval."
        "completed" -> "Your request completed successfully."
        "failed" -> "Your request could not be completed."
      end

    agent = safe_metadata(job.selected_agent)
    tool = safe_metadata(job.proposed_tool)

    details =
      [
        "Job ID: #{job.id}",
        "Status: #{job.status}",
        if(agent, do: "Agent: #{agent}", else: nil),
        if(tool, do: "Tool: #{tool}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    body = """
    #{status_text}

    #{details}

    Open Agentic ITSM:
    #{config.frontend_base_url}

    This notification was generated from durable backend job state.
    No LLM-generated recommendation text is included in this email.
    """

    {subject, body}
  end

  defp safe_metadata(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> String.slice(normalized, 0, 160)
    end
  end

  defp safe_metadata(_value), do: nil

  defp normalize_name(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      normalized -> String.slice(normalized, 0, 160)
    end
  end

  defp normalize_name(_value, fallback), do: fallback
end
