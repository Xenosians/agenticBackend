defmodule ItsmBackend.Mail.OutboxWorker do
  @moduledoc """
  Durable mail-outbox delivery worker.

  Delivery is provider-neutral and goes through `ItsmBackend.Mail`. A failure
  that provably submitted nothing, or an explicit temporary rejection, is
  rescheduled with a bound. Ambiguous delivery and interrupted claims are
  quarantined for operator reconciliation and never sent again automatically.
  """

  use GenServer

  require Logger

  alias ItsmBackend.Mail
  alias ItsmBackend.Mail.OutboxStore

  # Connection-level failures that happen before a request reaches the provider.
  @unreached_transport_errors [:econnrefused, :nxdomain, :ehostunreach, :enetunreach]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      poll_interval_ms: Keyword.fetch!(opts, :poll_interval_ms),
      lease_seconds: Keyword.fetch!(opts, :lease_seconds),
      max_attempts: Keyword.fetch!(opts, :max_attempts),
      store: Keyword.get(opts, :store, OutboxStore),
      mail: Keyword.get(opts, :mail, Mail)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    delay =
      case claim_next(state.store, state.lease_seconds) do
        {:ok, nil} ->
          state.poll_interval_ms

        {:ok, message} ->
          deliver_claimed(message, state)
          0

        {:error, reason} ->
          Logger.error("mail outbox claim failed: " <> sanitize_reason(reason))
          state.poll_interval_ms
      end

    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  # A storage hiccup must not crash the worker: log it and poll again later.
  defp claim_next(store, lease_seconds) do
    store.claim_next(lease_seconds)
  rescue
    error -> {:error, {:claim_raised, Exception.message(error)}}
  end

  defp deliver_claimed(message, state) do
    id = Map.fetch!(message, "outbox_id")
    attempt = Map.fetch!(message, "attempts")
    store = state.store

    case deliver_message(message, state.mail) do
      {:ok, _metadata} ->
        case store.mark_sent(id, attempt) do
          :ok ->
            :ok

          {:error, reason} ->
            # The provider accepted the message. Never turn a failed durable
            # acknowledgement into permission to deliver it a second time.
            stop_delivery(
              store,
              id,
              attempt,
              "outcome_unknown",
              {:acknowledgement_failed, reason}
            )
        end

      {:error, reason} ->
        case delivery_failure(reason) do
          :retry ->
            report_update(
              store.reschedule_or_dead(id, attempt, state.max_attempts, failure_code(reason)),
              id
            )

          status ->
            stop_delivery(store, id, attempt, status, reason)
        end
    end
  end

  defp deliver_message(message, mail) do
    recipient_email = Map.fetch!(message, "recipient_email")

    recipient =
      case Map.get(message, "recipient_name") do
        value when is_binary(value) and value != "" -> {value, recipient_email}
        _ -> recipient_email
      end

    subject = Map.fetch!(message, "subject")
    text_body = Map.fetch!(message, "text_body")
    html_body = Map.get(message, "html_body")

    if is_binary(html_body) and String.trim(html_body) != "" do
      mail.deliver_multipart(recipient, subject, text_body, html_body)
    else
      mail.deliver_text(recipient, subject, text_body)
    end
  rescue
    error -> {:error, {:delivery_raised, error.__struct__}}
  catch
    kind, _reason -> {:error, {:delivery_interrupted, kind}}
  end

  # All unclassified failures are ambiguous. In particular, a 5xx response or
  # lost connection does not establish that an external send did not happen.
  defp delivery_failure({:brevo_transient_error, 429, _body}), do: :retry

  # The connection to the provider was never established: nothing was sent.
  defp delivery_failure({:brevo_request_failed, %{reason: reason}})
       when reason in @unreached_transport_errors,
       do: :retry

  # SMTP lab relay (gen_smtp). retries_exceeded and no_more_hosts are only
  # returned while opening the session, before any message is submitted. A
  # definitive reply to the submission ends or reschedules it; any other
  # failure during the submission stays ambiguous.
  defp delivery_failure({:retries_exceeded, _session_failure}), do: :retry
  defp delivery_failure({:no_more_hosts, {:permanent_failure, _host, _reply}}), do: "dead"
  defp delivery_failure({:send, {:permanent_failure, _host, _reply}}), do: "dead"
  defp delivery_failure({:send, {:temporary_failure, _host, _reply}}), do: :retry

  defp delivery_failure({:brevo_delivery_rejected, status, _body}) when status in 400..499,
    do: "dead"

  defp delivery_failure(reason)
       when reason in [
              :missing_brevo_api_key,
              :invalid_mail_address,
              :invalid_mail_recipient,
              :lab_mail_disabled
            ],
       do: "dead"

  defp delivery_failure({:unsupported_mailer_mode, _mode}), do: "dead"
  defp delivery_failure(_reason), do: "outcome_unknown"

  defp stop_delivery(store, id, attempt, status, reason) do
    report_update(store.stop_delivery(id, attempt, status, failure_code(reason)), id)
  end

  defp report_update(:ok, _id), do: :ok

  defp report_update({:error, reason}, id) do
    # An unacknowledged claim stays processing; expiry quarantines it instead
    # of reclaiming it for delivery, including when storage is still down.
    Logger.error("mail outbox outcome persistence failed id=#{id}: " <> sanitize_reason(reason))
  end

  # Persist a useful reason code, never an arbitrary provider response or a
  # transport exception that could include message content or credentials.
  defp failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code(reason) when is_tuple(reason), do: reason |> elem(0) |> failure_code()
  defp failure_code(_reason), do: "mail_delivery_outcome_unknown"

  defp sanitize_reason(reason) do
    inspect(reason, pretty: false, limit: 20, printable_limit: 1_000)
    |> String.slice(0, 1_000)
  end
end
