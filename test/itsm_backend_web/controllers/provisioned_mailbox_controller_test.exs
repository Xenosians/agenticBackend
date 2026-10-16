defmodule ItsmBackendWeb.ProvisionedMailboxControllerTest do
  use ItsmBackendWeb.ConnCase, async: false

  @internal_token "mailbox-private-internal-token"

  setup do
    originals =
      Map.new([:internal_job_token, :credential_vault, :mailbox_lab_domain], fn key ->
        {key, Application.get_env(:itsm_backend, key)}
      end)

    Application.put_env(:itsm_backend, :internal_job_token, @internal_token)
    Application.put_env(:itsm_backend, :mailbox_lab_domain, "itsm.test")

    Application.put_env(:itsm_backend, :credential_vault,
      key_b64: Base.encode64(:crypto.strong_rand_bytes(32)),
      key_version: "mailbox-controller-test-v1",
      ttl_seconds: 3_600
    )

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> Application.delete_env(:itsm_backend, key)
        {key, value} -> Application.put_env(:itsm_backend, key, value)
      end)
    end)

    :ok
  end

  test "requires internal authentication even with a valid payload", %{conn: conn} do
    assert conn |> post_mailbox(valid_payload(), nil) |> json_response(401) == %{
             "error" => "unauthorized"
           }

    assert build_conn() |> post_mailbox(valid_payload(), "wrong-token") |> json_response(401) ==
             %{"error" => "unauthorized"}
  end

  test "authenticated creation returns only mailbox metadata and credential references", %{
    conn: conn
  } do
    payload = valid_payload()
    result = conn |> post_mailbox(payload) |> json_response(201)
    assert result["email"] == payload["email"]
    assert result["provider"] == "maddy"
    assert is_binary(result["mailbox_record_id"])
    assert is_binary(result["credential_id"])
    assert is_binary(result["credential_expires_at"])
    refute Jason.encode!(result) =~ payload["temporary_password"]
    refute Map.has_key?(result, "directory_user_id")
  end

  test "rejects ambiguous duplicate internal-token headers", %{conn: conn} do
    conn = %{
      conn
      | req_headers: [{"x-internal-token", @internal_token}, {"x-internal-token", "other-token"}]
    }

    assert conn |> post_mailbox(valid_payload(), nil) |> json_response(401) == %{
             "error" => "unauthorized"
           }
  end

  test "rejects public domains, unsupported providers, and unknown request fields", %{conn: conn} do
    assert conn
           |> post_mailbox(Map.put(valid_payload(), "email", "user@example.com"))
           |> json_response(422) ==
             %{"error" => "invalid_request", "field" => "email"}

    assert build_conn()
           |> post_mailbox(Map.put(valid_payload(), "provider", "other"))
           |> json_response(422) ==
             %{"error" => "invalid_request", "field" => "provider"}

    assert build_conn()
           |> post_mailbox(Map.put(valid_payload(), "directory_user_id", "invented"))
           |> json_response(422) ==
             %{"error" => "invalid_request"}
  end

  test "does not overwrite an existing mailbox", %{conn: conn} do
    payload = valid_payload()
    assert conn |> post_mailbox(payload) |> json_response(201)

    assert build_conn() |> post_mailbox(payload) |> json_response(409) == %{
             "error" => "mailbox_already_persisted"
           }
  end

  test "configuration errors do not expose secrets", %{conn: conn} do
    Application.delete_env(:itsm_backend, :credential_vault)
    result = conn |> post_mailbox(valid_payload()) |> json_response(503)
    assert result == %{"error" => "credential_vault_configuration"}
    refute Jason.encode!(result) =~ valid_payload()["temporary_password"]
  end

  test "has no public or internal credential fetch route", %{conn: conn} do
    assert conn |> get("/api/internal/v1/provisioned-mailboxes/missing") |> response(404)
    assert build_conn() |> get("/api/v1/provisioned-mailboxes/missing") |> response(404)
  end

  defp valid_payload do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    %{
      "provider" => "maddy",
      "email" => "controller#{suffix}@itsm.test",
      "temporary_password" => "Controller-Mailbox-Secret!42",
      "verification" => %{"smtp" => false, "imap" => false}
    }
  end

  defp post_mailbox(conn, payload, token \\ @internal_token) do
    conn = put_req_header(conn, "content-type", "application/json")
    conn = if token, do: put_req_header(conn, "x-internal-token", token), else: conn
    post(conn, ~p"/api/internal/v1/provisioned-mailboxes", Jason.encode!(payload))
  end
end
