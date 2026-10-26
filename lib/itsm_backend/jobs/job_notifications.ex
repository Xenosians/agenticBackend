defmodule ItsmBackend.Jobs.JobNotifications do
  @moduledoc """
  Deterministic AI-job email notifications.

  Notification content is derived only from durable job state and trusted
  backend metadata. No LLM-generated recommendation text is used.

  Successful-task mail requires the deployment switch and the owner's optional
  completion preference. Approval, failure and reconciliation notices remain
  independent, as do explicitly requested notifications and authentication mail.
  """

  require Logger

  alias ItsmBackend.Auth.SurrealStore, as: AuthStore
  alias ItsmBackend.Auth.Preferences
  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Mail.OutboxStore
  alias ItsmBackend.RuntimeConfig

  @notifiable_statuses [
    "waiting_approval",
    "reconciliation_required",
    "outcome_unknown",
    "denied",
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
  def enqueue(%Job{status: "completed"} = job) do
    if RuntimeConfig.task_completion_mail!().enabled do
      enqueue_notification(job)
    else
      {:ok, :disabled}
    end
  end

  def enqueue(%Job{status: status} = job) when status in @notifiable_statuses do
    enqueue_notification(job)
  end

  def enqueue(%Job{}), do: {:ok, :not_required}

  defp enqueue_notification(%Job{} = job) do
    with {:ok, user} <- AuthStore.get_user(job.user_id),
         {:ok, enabled} <- enabled_for_user(job, user),
         {:ok, recipient} <- recipient_when_enabled(enabled, user) do
      enqueue_for_recipient(job, recipient)
    end
  end

  defp enabled_for_user(%Job{status: "completed"}, user) when is_map(user) do
    with {:ok, preferences} <- Preferences.from_user(user) do
      {:ok, preferences["task_completed"]}
    end
  end

  defp enabled_for_user(_job, _user), do: {:ok, true}
  defp recipient_when_enabled(false, _user), do: {:ok, :disabled}
  defp recipient_when_enabled(true, user), do: recipient_from_user(user)

  defp enqueue_for_recipient(_job, :disabled), do: {:ok, :disabled}
  defp enqueue_for_recipient(_job, :not_applicable), do: {:ok, :not_applicable}

  defp enqueue_for_recipient(job, %{name: name, email: email}) do
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

    event =
      case job.status do
        "waiting_approval" ->
          "approval required"

        status when status in ["reconciliation_required", "outcome_unknown"] ->
          "reconciliation required"

        "completed" ->
          "request completed"

        "denied" ->
          "request denied"

        "failed" ->
          "request failed"
      end

    subject = "#{config.mail_from_name} — #{event}"

    status_text =
      case job.status do
        "waiting_approval" ->
          "Your request is waiting for approval."

        status when status in ["reconciliation_required", "outcome_unknown"] ->
          "The approved action has an unresolved execution outcome. Automatic retry is disabled and trusted reconciliation is required."

        "completed" ->
          "Your request completed successfully."

        "denied" ->
          denial_message(job)

        "failed" ->
          "Your request could not be completed."
      end

    agent = safe_metadata(job.selected_agent)
    tool = tool_metadata(job.proposed_tool)

    details =
      [
        "Job ID: #{job.id}",
        "Status: #{job.status}",
        if(agent, do: "Agent: #{agent}", else: nil),
        if(tool, do: "Tool: #{tool}", else: nil)
      ]
      |> Kernel.++(workflow_details(job))
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    body = """
    #{status_text}

    #{details}

    Open #{config.mail_from_name}:
    #{config.frontend_base_url}

    This notification was generated from durable backend job state.
    No LLM-generated recommendation text is included in this email.
    """

    {subject, body}
  end

  defp workflow_details(%Job{
         status: "completed",
         result: %{
           "workflow" => %{"kind" => "account_ticket", "state" => "completed"} = workflow,
           "approval_execution" => execution
         }
       }) do
    account = safe_metadata(get_in(workflow, ["account", "user_id"]))
    ticket = safe_metadata(get_in(execution, ["result", "ticket_key"]))

    [
      if(account, do: "Created account: #{account}"),
      if(ticket, do: "Created Jira ticket: #{ticket}")
    ]
  end

  defp workflow_details(_job), do: []

  defp denial_message(%Job{
         result: %{"approval_execution" => %{"execution_status" => "rejected"}}
       }),
       do: "You rejected the proposed action. No tool was executed."

  defp denial_message(_job),
    do:
      "A requested operation was denied by policy. Review the job details before submitting another request."

  defp tool_metadata(%{"tool" => tool}), do: safe_metadata(tool)
  defp tool_metadata(tool), do: safe_metadata(tool)

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
