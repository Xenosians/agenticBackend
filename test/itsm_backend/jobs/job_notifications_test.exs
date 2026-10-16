defmodule ItsmBackend.Jobs.JobNotificationsTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.JobNotifications
  alias ItsmBackend.Mail.OutboxStore
  alias ItsmBackend.Surreal
  alias ItsmBackendWeb.AuthTestSupport

  setup do
    identity = AuthTestSupport.authenticated_identity!()

    {:ok, job} =
      Jobs.create(%{
        user_id: identity.user["user_id"],
        conversation_id: identity.chat["chat_id"],
        message: "A request with private user content."
      })

    %{job: %{job | attempts: 1, proposed_tool: %{"tool" => "workspace_mkdir"}}}
  end

  test "completed task mail is durable, deduplicated and does not copy model content", %{job: job} do
    completed = %{job | status: "completed", result: %{"answer" => "private-model-output"}}
    assert {:ok, first} = JobNotifications.enqueue(completed)
    assert first["dedupe_key"] == "job:#{job.id}:1:completed"
    assert {:ok, second} = JobNotifications.enqueue(completed)
    assert first["outbox_id"] == second["outbox_id"]
    assert first["subject"] == "Agentic ITSM — request completed"
    assert first["text_body"] =~ "Tool: workspace_mkdir"
    refute first["text_body"] =~ "private-model-output"
    refute first["text_body"] =~ job.message
    assert {:ok, stored} = OutboxStore.get(first["outbox_id"])
    assert stored["dedupe_key"] == "job:#{job.id}:1:completed"
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
