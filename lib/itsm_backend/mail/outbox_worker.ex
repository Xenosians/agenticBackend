defmodule ItsmBackend.Mail.OutboxWorker do
  @moduledoc """
  Durable mail-outbox delivery worker.

  Delivery is provider-neutral and goes through `ItsmBackend.Mail`. Failed
  deliveries are rescheduled with bounded exponential backoff.
  """

  use GenServer

  require Logger

  alias ItsmBackend.Mail
  alias ItsmBackend.Mail.OutboxStore

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      poll_interval_ms: Keyword.fetch!(opts, :poll_interval_ms),
      lease_seconds: Keyword.fetch!(opts, :lease_seconds),
      max_attempts: Keyword.fetch!(opts, :max_attempts)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    delay =
      case OutboxStore.claim_next(state.lease_seconds) do
        {:ok, nil} ->
          state.poll_interval_ms

        {:ok, message} ->
          deliver_claimed(message, state.max_attempts)
          0

        {:error, reason} ->
          Logger.error("mail outbox claim failed: " <> sanitize_reason(reason))
          state.poll_interval_ms
      end

    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  defp deliver_claimed(message, max_attempts) do
    id = Map.fetch!(message, "outbox_id")
    recipient_email = Map.fetch!(message, "recipient_email")

    recipient =
      case Map.get(message, "recipient_name") do
        value when is_binary(value) and value != "" -> {value, recipient_email}
        _ -> recipient_email
      end

    subject = Map.fetch!(message, "subject")
    text_body = Map.fetch!(message, "text_body")
    html_body = Map.get(message, "html_body")

    delivery =
      if is_binary(html_body) and String.trim(html_body) != "" do
        Mail.deliver_multipart(recipient, subject, text_body, html_body)
      else
        Mail.deliver_text(recipient, subject, text_body)
      end

    case delivery do
      {:ok, _metadata} ->
        case OutboxStore.mark_sent(id) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "mail delivered but outbox acknowledgement failed id=#{id}: " <>
                sanitize_reason(reason)
            )
        end

      {:error, reason} ->
        attempts = Map.get(message, "attempts", 1)

        case OutboxStore.reschedule_or_dead(
               id,
               attempts,
               max_attempts,
               sanitize_reason(reason)
             ) do
          :ok ->
            :ok

          {:error, update_reason} ->
            Logger.error(
              "mail outbox reschedule failed id=#{id}: " <>
                sanitize_reason(update_reason)
            )
        end
    end
  end

  defp sanitize_reason(reason) do
    inspect(reason, pretty: false, limit: 20, printable_limit: 1_000)
    |> String.slice(0, 1_000)
  end
end
