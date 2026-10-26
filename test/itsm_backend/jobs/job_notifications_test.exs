defmodule ItsmBackend.Jobs.JobNotificationsTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.JobNotifications
  alias ItsmBackend.Mail.OutboxStore
  alias ItsmBackend.Surreal
  alias ItsmBackendWeb.AuthTestSupport

  setup do
    original = Application.get_env(:itsm_backend, :task_completion_mail)
    Application.put_env(:itsm_backend, :task_completion_mail, enabled: true)

    on_exit(fn ->
      Application.put_env(:itsm_backend, :task_completion_mail, original)
    end)

    identity = AuthTestSupport.authenticated_identity!()

    {:ok, job} =
      Jobs.create(%{
        user_id: identity.user["user_id"],
        conversation_id: identity.chat["chat_id"],
        message: "A request with private user content."
      })

    %{
      identity: identity,
      job: %{job | attempts: 1, proposed_tool: %{"tool" => "workspace_mkdir"}}
    }
  end

  test "disabled completion mail creates no outbox record and leaves other lifecycle notices enabled",
       %{
         job: job
       } do
    Application.put_env(:itsm_backend, :task_completion_mail, enabled: false)
    completed = %{job | status: "completed"}
    assert {:ok, :disabled} = JobNotifications.enqueue(completed)

    id =
      :crypto.hash(:sha256, "job:#{job.id}:1:completed")
      |> Base.encode16(case: :lower)

    assert {:error, :not_found} = OutboxStore.get(id)

    for status <- [
          "waiting_approval",
          "failed",
          "denied",
          "outcome_unknown",
          "reconciliation_required"
        ] do
      assert {:ok, notice} = JobNotifications.enqueue(%{job | status: status})
      assert notice["status"] == "pending"
      assert notice["dedupe_key"] == "job:#{job.id}:1:#{status}"
    end

    Application.put_env(:itsm_backend, :task_completion_mail, enabled: true)
    assert {:ok, notification} = JobNotifications.enqueue(completed)
    assert notification["outbox_id"] == id
    assert notification["status"] == "pending"
    assert {:ok, replay} = JobNotifications.enqueue(completed)
    assert replay["outbox_id"] == notification["outbox_id"]
  end

  test "disabled automatic completion mail preserves explicitly requested user notifications", %{
    identity: identity,
    job: job
  } do
    Application.put_env(:itsm_backend, :task_completion_mail, enabled: false)

    assert {:ok, notification} =
             ItsmBackend.UserNotifications.enqueue(%{
               "email" => identity.user["email"],
               "message" => "The explicitly approved work has finished.",
               "dedupe_key" => "explicit-completion:#{job.id}"
             })

    assert notification.queued
    assert notification.delivery_status == "pending"
    assert {:ok, record} = OutboxStore.get(notification.outbox_id)
    assert record["kind"] == "user_notification"
    assert record["recipient_email"] == identity.user["email"]
  end

  test "completed task mail is durable, deduplicated and does not copy model content", %{job: job} do
    completed = %{job | status: "completed", result: %{"answer" => "private-model-output"}}
    assert {:ok, first} = JobNotifications.enqueue(completed)
    assert first["dedupe_key"] == "job:#{job.id}:1:completed"
    assert {:ok, second} = JobNotifications.enqueue(completed)
    assert first["outbox_id"] == second["outbox_id"]
    product = ItsmBackend.RuntimeConfig.auth!().mail_from_name
    assert first["subject"] == "#{product} — request completed"
    assert first["text_body"] =~ "Tool: workspace_mkdir"
    refute first["text_body"] =~ "private-model-output"
    refute first["text_body"] =~ job.message
    assert {:ok, stored} = OutboxStore.get(first["outbox_id"])
    assert stored["dedupe_key"] == "job:#{job.id}:1:completed"
  end

  test "owner preference disables only new completion mail and preserves already queued mail", %{
    identity: owner,
    job: job
  } do
    alias ItsmBackend.Auth.Preferences
    completed = %{job | status: "completed"}
    assert {:ok, queued} = JobNotifications.enqueue(completed)

    assert {:ok, %{"task_completed" => false}} =
             Preferences.save(owner.user["user_id"], %{"task_completed" => false})

    assert {:ok, :disabled} = JobNotifications.enqueue(%{completed | id: job.id <> "-disabled"})
    assert {:ok, still_queued} = OutboxStore.get(queued["outbox_id"])
    assert still_queued["status"] == "pending"

    for status <- [
          "waiting_approval",
          "failed",
          "denied",
          "outcome_unknown",
          "reconciliation_required"
        ] do
      assert {:ok, notice} = JobNotifications.enqueue(%{job | status: status})
      assert notice["status"] == "pending"
    end

    assert {:ok, _} =
             ItsmBackend.UserNotifications.enqueue(%{
               "email" => owner.user["email"],
               "message" => "Requested notice",
               "dedupe_key" => "explicit-preference:#{job.id}"
             })

    assert {:ok, %{"task_completed" => true}} =
             Preferences.save(owner.user["user_id"], %{"task_completed" => true})

    assert {:ok, enabled} = JobNotifications.enqueue(%{completed | id: job.id <> "-enabled"})
    assert enabled["status"] == "pending"
    Application.put_env(:itsm_backend, :task_completion_mail, enabled: false)

    assert {:ok, :disabled} =
             JobNotifications.enqueue(%{completed | id: job.id <> "-master-disabled"})
  end

  test "invalid stored completion preference never sends or changes the task", %{
    identity: owner,
    job: job
  } do
    assert {:ok, _} =
             Surreal.query(
               "UPDATE ONLY type::record('app_user', $id) SET notification_preferences = $bad;",
               %{"id" => owner.user["user_id"], "bad" => %{"task_completed" => "yes"}}
             )

    completed = %{job | status: "completed"}
    assert {:error, :invalid_stored_preferences} = JobNotifications.enqueue(completed)
    assert :ok = JobNotifications.enqueue_best_effort(completed)
    assert {:ok, notice} = JobNotifications.enqueue(%{job | status: "failed"})
    assert notice["status"] == "pending"
  end

  test "human rejection and policy denial have distinct truthful notification text", %{job: job} do
    rejected = %{
      job
      | status: "denied",
        result: %{"approval_execution" => %{"execution_status" => "rejected"}}
    }

    assert {:ok, mail} = JobNotifications.enqueue(rejected)
    assert mail["text_body"] =~ "You rejected the proposed action. No tool was executed."
    refute mail["text_body"] =~ "denied by policy"

    policy_denied = %{job | id: job.id <> "-policy", status: "denied"}
    assert {:ok, policy_mail} = JobNotifications.enqueue(policy_denied)
    assert policy_mail["text_body"] =~ "denied by policy"
  end

  test "approval, completion and a later attempt retain distinct durable notification keys", %{
    job: job
  } do
    waiting = %{job | status: "waiting_approval"}
    completed = %{job | status: "completed"}
    later = %{completed | attempts: 2}

    assert {:ok, pending_mail} = JobNotifications.enqueue(waiting)
    assert {:ok, completed_mail} = JobNotifications.enqueue(completed)
    assert {:ok, later_mail} = JobNotifications.enqueue(later)

    assert pending_mail["dedupe_key"] == "job:#{job.id}:1:waiting_approval"
    assert completed_mail["dedupe_key"] == "job:#{job.id}:1:completed"
    assert later_mail["dedupe_key"] == "job:#{job.id}:2:completed"

    ids = Enum.map([pending_mail, completed_mail, later_mail], & &1["outbox_id"])
    assert length(Enum.uniq(ids)) == 3

    for mail <- [pending_mail, completed_mail, later_mail] do
      assert {:ok, stored} = OutboxStore.get(mail["outbox_id"])
      assert stored["dedupe_key"] == mail["dedupe_key"]
    end
  end

  test "outbox persists record-shaped text as literal text", %{job: job} do
    body = "job:#{job.id}:1:completed"

    assert {:ok, first} =
             OutboxStore.enqueue(%{
               "dedupe_key" => "job:#{job.id}:1:text-roundtrip",
               "recipient_email" => "fixture@example.invalid",
               "recipient_name" => "person:fixture:display",
               "subject" => "notification:task:completed",
               "text_body" => body,
               "html_body" => "<p>job:#{job.id}:1:completed</p>"
             })

    assert {:ok, stored} = OutboxStore.get(first["outbox_id"])
    assert stored["recipient_name"] == "person:fixture:display"
    assert stored["subject"] == "notification:task:completed"
    assert stored["text_body"] == body
    assert stored["html_body"] == "<p>job:#{job.id}:1:completed</p>"

    assert {:ok, [%{"result" => timestamps}]} =
             Surreal.query(
               """
               SELECT type::is_datetime(created_at) AS created_at,
                      type::is_datetime(next_attempt_at) AS next_attempt_at
               FROM ONLY type::record('mail_outbox', $id);
               """,
               %{"id" => first["outbox_id"]}
             )

    assert timestamps["created_at"]
    assert timestamps["next_attempt_at"]
  end
end
