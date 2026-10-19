defmodule ItsmBackend.Mail.OutboxWorkerTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.Mail.OutboxStore
  alias ItsmBackend.Mail.OutboxWorker
  alias ItsmBackend.Surreal

  setup do
    # test_helper has already enforced an isolated test database.
    assert {:ok, _} = Surreal.query("DELETE mail_outbox;")
    :ok
  end

  test "provider receipt followed by lost acknowledgement is not sent a second time" do
    message = enqueue()
    Process.put(:fixture_mail_result, {:error, {:brevo_request_failed, :closed}})

    poll()
    assert_receive :fixture_provider_received_message
    assert_status(message, "outcome_unknown")
    poll()
    refute_received :fixture_provider_received_message
  end

  test "a server failure and a raised sender both quarantine potentially accepted mail" do
    for result <- [{:error, {:brevo_transient_error, 503, %{}}}, :raise] do
      message = enqueue()
      Process.put(:fixture_mail_result, result)
      poll()
      assert_receive :fixture_provider_received_message
      assert_status(message, "outcome_unknown")
      poll()
      refute_received :fixture_provider_received_message
    end
  end

  test "provider success followed by failed durable acknowledgement is quarantined" do
    message = enqueue()
    Process.put(:fixture_mail_result, {:ok, %{message_id: "fixture-provider-id"}})

    poll(ItsmBackend.MailOutboxAckFailureStore)
    assert_receive :fixture_provider_received_message
    assert_status(message, "outcome_unknown")
    poll()
    refute_received :fixture_provider_received_message
  end

  test "a sender crash during storage outage remains unknown after lease recovery" do
    message = enqueue()
    Process.put(:fixture_mail_result, {:ok, %{message_id: "fixture-provider-id"}})
    Process.put(:fixture_all_outbox_writes_fail, true)

    poll(ItsmBackend.MailOutboxAckFailureStore)
    assert_receive :fixture_provider_received_message
    assert_status(message, "processing")

    expire_claim(message)
    poll()
    assert_status(message, "outcome_unknown")
    refute_received :fixture_provider_received_message
  end

  test "a lost database acknowledgement never replaces a committed sent state or resends" do
    message = enqueue()
    Process.put(:fixture_mail_result, {:ok, %{message_id: "fixture-provider-id"}})
    Process.put(:fixture_acknowledgement_was_committed, true)

    poll(ItsmBackend.MailOutboxAckFailureStore)
    assert_receive :fixture_provider_received_message
    assert_status(message, "sent")
    poll()
    refute_received :fixture_provider_received_message
  end

  test "an interrupted claimed send is quarantined even if its sender never returned" do
    message = enqueue()
    assert {:ok, %{"outbox_id" => id}} = OutboxStore.claim_next(60)
    assert id == message["outbox_id"]
    expire_claim(message)

    poll()
    assert_status(message, "outcome_unknown")
    refute_received :fixture_provider_received_message
  end

  test "definitive rate-limit rejection retries with a bound and permanent rejection is dead" do
    message = enqueue()
    Process.put(:fixture_mail_result, {:error, {:brevo_transient_error, 429, %{}}})
    poll()
    assert_receive :fixture_provider_received_message

    assert {:ok, %{"status" => "pending", "attempts" => 1}} =
             OutboxStore.get(message["outbox_id"])

    make_due(message)
    poll(OutboxStore, 2)
    assert_receive :fixture_provider_received_message
    assert_status(message, "dead")

    permanent = enqueue()
    Process.put(:fixture_mail_result, {:error, {:brevo_delivery_rejected, 401, %{}}})
    poll()
    assert_receive :fixture_provider_received_message
    assert_status(permanent, "dead")
    poll()
    refute_received :fixture_provider_received_message
  end

  test "a failure before anything reached the mail server is rescheduled, not quarantined" do
    unreached = [
      {:error, {:brevo_request_failed, %Req.TransportError{reason: :econnrefused}}},
      {:error, {:brevo_request_failed, %Req.TransportError{reason: :nxdomain}}},
      {:error, {:retries_exceeded, {:network_failure, "127.0.0.1", {:error, :econnrefused}}}},
      {:error, {:send, {:temporary_failure, "127.0.0.1", "451 try again later"}}}
    ]

    for result <- unreached do
      message = enqueue()
      Process.put(:fixture_mail_result, result)
      poll()
      assert_receive :fixture_provider_received_message

      assert {:ok, %{"status" => "pending", "attempts" => 1}} =
               OutboxStore.get(message["outbox_id"])

      # The next due attempt sends it.
      make_due(message)
      Process.put(:fixture_mail_result, {:ok, %{message_id: "fixture-provider-id"}})
      poll()
      assert_receive :fixture_provider_received_message
      assert_status(message, "sent")
    end
  end

  test "smtp outcomes keep definitive rejection and ambiguous submission apart" do
    for {result, expected} <- [
          {{:error, {:no_more_hosts, {:permanent_failure, "127.0.0.1", "535 auth failed"}}},
           "dead"},
          {{:error, {:send, {:permanent_failure, "127.0.0.1", "550 mailbox unavailable"}}},
           "dead"},
          {{:error, {:send, {:network_failure, "127.0.0.1", {:error, :closed}}}},
           "outcome_unknown"},
          {{:error, {:brevo_request_failed, %Req.TransportError{reason: :timeout}}},
           "outcome_unknown"}
        ] do
      message = enqueue()
      Process.put(:fixture_mail_result, result)
      poll()
      assert_receive :fixture_provider_received_message
      assert_status(message, expected)
      poll()
      refute_received :fixture_provider_received_message
    end
  end

  test "confirmed provider acceptance is recorded once, and stale claims cannot overwrite it" do
    message = enqueue()
    Process.put(:fixture_mail_result, {:ok, %{message_id: "fixture-provider-id"}})
    poll()
    assert_receive :fixture_provider_received_message
    assert_status(message, "sent")

    assert {:error, :not_found} =
             OutboxStore.stop_delivery(message["outbox_id"], 1, "dead", "stale")

    poll()
    refute_received :fixture_provider_received_message
  end

  test "a stale attempt cannot acknowledge, reschedule or quarantine another claim" do
    message = enqueue()
    assert {:ok, %{"attempts" => 1}} = OutboxStore.claim_next(60)
    id = message["outbox_id"]

    assert {:error, :not_found} = OutboxStore.mark_sent(id, 2)
    assert {:error, :not_found} = OutboxStore.reschedule_or_dead(id, 2, 3, "stale")
    assert {:error, :not_found} = OutboxStore.stop_delivery(id, 2, "outcome_unknown", "stale")
    assert_status(message, "processing")
  end

  defp poll(store \\ OutboxStore, max_attempts \\ 3) do
    state = %{
      store: store,
      mail: ItsmBackend.MailOutboxTestTransport,
      poll_interval_ms: 1_000_000,
      lease_seconds: 60,
      max_attempts: max_attempts
    }

    assert {:noreply, ^state} = OutboxWorker.handle_info(:poll, state)
  end

  defp enqueue do
    assert {:ok, record} =
             OutboxStore.enqueue(%{
               "dedupe_key" => "mail-audit-" <> Base.encode16(:crypto.strong_rand_bytes(16)),
               "recipient_email" => "fixture@example.invalid",
               "subject" => "Fixture notification",
               "text_body" => "Fixture content"
             })

    record
  end

  defp assert_status(message, expected) do
    assert {:ok, %{"status" => ^expected}} = OutboxStore.get(message["outbox_id"])
  end

  defp expire_claim(message) do
    assert {:ok, _} =
             Surreal.query(
               """
               UPDATE ONLY type::record('mail_outbox', $id)
               SET lease_expires_at = <datetime>$past;
               """,
               %{"id" => message["outbox_id"], "past" => "2000-01-01T00:00:00Z"}
             )
  end

  defp make_due(message) do
    assert {:ok, _} =
             Surreal.query(
               """
               UPDATE ONLY type::record('mail_outbox', $id)
               SET next_attempt_at = <datetime>$past;
               """,
               %{"id" => message["outbox_id"], "past" => "2000-01-01T00:00:00Z"}
             )
  end
end
