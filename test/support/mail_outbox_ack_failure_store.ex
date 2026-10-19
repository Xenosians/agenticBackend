defmodule ItsmBackend.MailOutboxAckFailureStore do
  @moduledoc false
  alias ItsmBackend.Mail.OutboxStore

  defdelegate claim_next(lease), to: OutboxStore

  def mark_sent(id, attempt) do
    if Process.get(:fixture_acknowledgement_was_committed, false) do
      :ok = OutboxStore.mark_sent(id, attempt)
    end

    {:error, :fixture_acknowledgement_lost}
  end

  def stop_delivery(id, attempt, status, reason) do
    if Process.get(:fixture_all_outbox_writes_fail, false),
      do: {:error, :fixture_storage_unavailable},
      else: OutboxStore.stop_delivery(id, attempt, status, reason)
  end
end
