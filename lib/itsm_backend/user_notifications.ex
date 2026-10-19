defmodule ItsmBackend.UserNotifications do
  @moduledoc """
  Approved notifications from the AI service to registered application users.

  The recipient must be an active, verified application user; the address is
  taken from the stored identity, never from the caller. Messages are plain text
  and new messages are queued in the durable mail outbox. Idempotent retries
  report the stored delivery state, including failure and uncertainty. "sent"
  records provider acceptance, not confirmed receipt in the recipient's inbox.
  """

  alias ItsmBackend.Auth
  alias ItsmBackend.Mail.OutboxStore
  alias ItsmBackend.RuntimeConfig

  @required ~w(email message dedupe_key)
  @optional ~w(subject)
  @max_message_length 4_000
  @max_subject_length 160
  @dedupe_key ~r/\A[A-Za-z0-9][A-Za-z0-9:_.-]{15,199}\z/
  # Plain text keeps line breaks and tabs; other control characters are dropped.
  @control_characters ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u

  @spec enqueue(map()) :: {:ok, map()} | {:error, term()}
  def enqueue(attrs) when is_map(attrs) do
    with :ok <- validate_fields(attrs),
         {:ok, message} <- message(attrs["message"]),
         {:ok, subject} <- subject(attrs["subject"]),
         {:ok, dedupe_key} <- dedupe_key(attrs["dedupe_key"]),
         {:ok, recipient} <- recipient(attrs["email"]) do
      {subject, text_body} = render(subject, message)

      notification = %{
        "dedupe_key" => dedupe_key,
        "kind" => "user_notification",
        "recipient_name" => recipient.name,
        "recipient_email" => recipient.email,
        "subject" => subject,
        "text_body" => text_body
      }

      with {:ok, record} <- OutboxStore.enqueue(notification),
           :ok <- same_notification(record, notification) do
        delivery_state(record, recipient.email)
      end
    end
  end

  def enqueue(_attrs), do: {:error, :invalid_payload}

  defp delivery_state(%{"status" => status} = record, email)
       when status in ["pending", "processing", "sent", "dead", "outcome_unknown"] do
    {:ok,
     %{
       outbox_id: record["outbox_id"],
       recipient_email: email,
       queued: status == "pending",
       delivery_status: status,
       reconciliation_required: status == "outcome_unknown"
     }}
  end

  defp delivery_state(_record, _email), do: {:error, :invalid_outbox_delivery_state}

  defp validate_fields(attrs) do
    keys = Map.keys(attrs)

    if Enum.all?(@required, &(&1 in keys)) and Enum.all?(keys, &(&1 in (@required ++ @optional))),
      do: :ok,
      else: {:error, :invalid_payload}
  end

  defp message(value) when is_binary(value) do
    text =
      value
      |> String.replace(~r/\r\n?/, "\n")
      |> String.replace(@control_characters, "")
      |> String.trim()

    if text != "" and String.length(text) <= @max_message_length,
      do: {:ok, text},
      else: {:error, {:invalid_field, "message"}}
  end

  defp message(_value), do: {:error, {:invalid_field, "message"}}

  defp subject(nil), do: {:ok, nil}

  defp subject(value) when is_binary(value) do
    text = String.trim(value)

    # A subject is a mail header: a line break could inject further headers.
    if text != "" and String.length(text) <= @max_subject_length and
         not Regex.match?(~r/[\x00-\x1F\x7F]/u, text),
       do: {:ok, text},
       else: {:error, {:invalid_field, "subject"}}
  end

  defp subject(_value), do: {:error, {:invalid_field, "subject"}}

  # Namespaced so a caller key can never collide with job notification keys.
  defp dedupe_key(value) when is_binary(value) do
    if Regex.match?(@dedupe_key, value),
      do: {:ok, "user_notification:" <> value},
      else: {:error, {:invalid_field, "dedupe_key"}}
  end

  defp dedupe_key(_value), do: {:error, {:invalid_field, "dedupe_key"}}

  defp recipient(email) do
    case Auth.find_user_by_email(email) do
      {:ok, %{"status" => "active", "email" => address} = user} when is_binary(address) ->
        {:ok, %{email: address, name: display_name(user, address)}}

      # Missing, unverified and disabled users are indistinguishable to the caller.
      {:ok, _not_notifiable} ->
        {:error, :recipient_not_found}

      {:error, :invalid_email} ->
        {:error, {:invalid_field, "email"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp display_name(user, fallback) do
    case user["display_name"] do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> fallback
          trimmed -> String.slice(trimmed, 0, 160)
        end

      _ ->
        fallback
    end
  end

  # The outbox returns the stored record when the key already exists; a reused
  # key must not report a different message as queued.
  defp same_notification(record, notification) do
    if Enum.all?(~w(kind recipient_email subject text_body), &(record[&1] == notification[&1])),
      do: :ok,
      else: {:error, :dedupe_conflict}
  end

  defp render(subject, message) do
    config = RuntimeConfig.auth!()

    body = """
    #{message}

    This notification was sent to you through #{config.mail_from_name} after an approved request.

    Open #{config.mail_from_name}:
    #{config.frontend_base_url}
    """

    # The outbox stores trimmed text; rendering the same form keeps the dedupe comparison exact.
    {subject || "#{config.mail_from_name} — notification", String.trim(body)}
  end
end
