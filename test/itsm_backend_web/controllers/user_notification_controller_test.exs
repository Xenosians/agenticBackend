defmodule ItsmBackendWeb.UserNotificationControllerTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.Auth
  alias ItsmBackend.Mail.OutboxStore
  alias ItsmBackend.Surreal
  alias ItsmBackendWeb.AuthTestSupport

  @internal_token "notification-private-internal-token"

  setup do
    original = Application.get_env(:itsm_backend, :internal_job_token)
    Application.put_env(:itsm_backend, :internal_job_token, @internal_token)

    on_exit(fn ->
      if original,
        do: Application.put_env(:itsm_backend, :internal_job_token, original),
        else: Application.delete_env(:itsm_backend, :internal_job_token)
    end)

    %{user: AuthTestSupport.authenticated_identity!().user}
  end

  test "requires the internal token", %{conn: conn, user: user} do
    payload = payload(user["email"])

    assert conn |> post_notification(payload, nil) |> json_response(401) == %{
             "error" => "unauthorized"
           }

    assert build_conn() |> post_notification(payload, "wrong-token") |> json_response(401) ==
             %{"error" => "unauthorized"}

    duplicate = %{
      build_conn()
      | req_headers: [{"x-internal-token", @internal_token}, {"x-internal-token", "other-token"}]
    }

    assert duplicate |> post_notification(payload, nil) |> json_response(401) == %{
             "error" => "unauthorized"
           }

    assert {:error, :not_found} = OutboxStore.get(outbox_id(payload))
  end

  test "queues one plain-text notification for a registered user", %{conn: conn, user: user} do
    payload =
      payload(String.upcase(user["email"]))
      |> Map.put("message", "Disk check finished.\r\nNo action needed.\u0007")
      |> Map.put("subject", "Maintenance update")

    result = conn |> post_notification(payload) |> json_response(202)

    assert result == %{
             "queued" => true,
             "outbox_id" => outbox_id(payload),
             "delivery_status" => "pending",
             "reconciliation_required" => false
           }

    assert {:ok, stored} = OutboxStore.get(result["outbox_id"])
    assert stored["kind"] == "user_notification"
    assert stored["status"] == "pending"
    # The stored identity address is used, not the caller's spelling of it.
    assert stored["recipient_email"] == user["email"]
    assert stored["recipient_name"] == user["display_name"]
    assert stored["subject"] == "Maintenance update"
    assert stored["dedupe_key"] == "user_notification:" <> payload["dedupe_key"]
    assert stored["text_body"] =~ "Disk check finished.\nNo action needed.\n"
    refute stored["text_body"] =~ "\u0007"
    assert stored["html_body"] == nil
  end

  test "a repeated request is deduplicated and a reused key with other content conflicts", %{
    conn: conn,
    user: user
  } do
    payload = payload(user["email"])
    first = conn |> post_notification(payload) |> json_response(202)
    second = build_conn() |> post_notification(payload) |> json_response(202)
    assert first == second

    changed = Map.put(payload, "message", "A different message.")

    assert build_conn() |> post_notification(changed) |> json_response(409) == %{
             "error" => "dedupe_conflict"
           }

    assert {:ok, stored} = OutboxStore.get(first["outbox_id"])
    assert stored["text_body"] =~ payload["message"]
    assert stored["subject"] =~ "notification"
  end

  test "unknown and unverified recipients are not found without enqueueing", %{conn: conn} do
    unknown = payload("nobody-#{suffix()}@example.test")

    assert conn |> post_notification(unknown) |> json_response(404) == %{
             "error" => "recipient_not_found"
           }

    pending_email = "pending-#{suffix()}@example.test"

    {:ok, _user, _token} =
      Auth.register(%{
        "email" => pending_email,
        "display_name" => "Pending user",
        "password" => "correct horse battery #{suffix()}!"
      })

    pending = payload(pending_email)

    assert build_conn() |> post_notification(pending) |> json_response(404) == %{
             "error" => "recipient_not_found"
           }

    for rejected <- [unknown, pending] do
      assert {:error, :not_found} = OutboxStore.get(outbox_id(rejected))
    end
  end

  test "duplicate requests report sent, failed, processing and uncertain states truthfully", %{
    user: user
  } do
    for {state, http_status, reconciliation?} <- [
          {"processing", 202, false},
          {"sent", 200, false},
          {"dead", 409, false},
          {"outcome_unknown", 409, true}
        ] do
      payload = payload(user["email"])
      first = build_conn() |> post_notification(payload) |> json_response(202)

      assert {:ok, _} =
               Surreal.query(
                 """
                 UPDATE ONLY type::record('mail_outbox', $id) SET status = $status;
                 """,
                 %{"id" => first["outbox_id"], "status" => state}
               )

      duplicate = build_conn() |> post_notification(payload) |> json_response(http_status)

      expected = %{
        "outbox_id" => first["outbox_id"],
        "queued" => false,
        "delivery_status" => state,
        "reconciliation_required" => reconciliation?
      }

      expected =
        case state do
          "dead" -> Map.put(expected, "error", "notification_delivery_failed")
          "outcome_unknown" -> Map.put(expected, "error", "notification_delivery_unknown")
          _ -> expected
        end

      assert duplicate == expected

      assert {:ok, stored} = OutboxStore.get(first["outbox_id"])
      assert stored["status"] == state
      assert stored["attempts"] == 0
    end
  end

  test "rejects invalid fields and unknown request fields", %{conn: conn, user: user} do
    valid = payload(user["email"])

    cases = [
      {Map.put(valid, "message", "   "), %{"error" => "invalid_request", "field" => "message"}},
      {Map.put(valid, "message", String.duplicate("a", 4_001)),
       %{"error" => "invalid_request", "field" => "message"}},
      {Map.put(valid, "subject", "Hello\r\nBcc: someone@example.test"),
       %{"error" => "invalid_request", "field" => "subject"}},
      {Map.put(valid, "dedupe_key", "short"),
       %{"error" => "invalid_request", "field" => "dedupe_key"}},
      {Map.put(valid, "email", "not-an-email"),
       %{"error" => "invalid_request", "field" => "email"}},
      {Map.delete(valid, "message"), %{"error" => "invalid_request"}},
      {Map.put(valid, "recipient_email", "other@example.test"), %{"error" => "invalid_request"}}
    ]

    for {payload, expected} <- cases do
      assert build_conn() |> post_notification(payload) |> json_response(422) == expected
    end

    assert conn |> get("/api/internal/v1/notifications") |> response(404)
  end

  defp payload(email) do
    %{
      "email" => email,
      "message" => "Matrix notification check #{suffix()}.",
      "dedupe_key" => "ai-notify-" <> suffix() <> suffix()
    }
  end

  defp outbox_id(payload) do
    :crypto.hash(:sha256, "user_notification:" <> payload["dedupe_key"])
    |> Base.encode16(case: :lower)
  end

  defp suffix, do: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

  defp post_notification(conn, payload, token \\ @internal_token) do
    conn = put_req_header(conn, "content-type", "application/json")
    conn = if token, do: put_req_header(conn, "x-internal-token", token), else: conn
    post(conn, ~p"/api/internal/v1/notifications", Jason.encode!(payload))
  end
end
