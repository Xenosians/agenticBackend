defmodule ItsmBackendWeb.CredentialHandoverTest do
  @moduledoc """
  The person who asked for an account receives its temporary password inside
  Janus, once, after confirming their own Janus password. The new person's
  address does not exist yet, so nothing depends on mailing them.
  """
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.{
    DirectoryCredentials,
    Jobs,
    ProvisionedAccounts,
    ProvisionedMailboxes,
    Surreal
  }

  alias ItsmBackend.Auth.SignInGuard
  alias ItsmBackend.Jobs.Job
  alias ItsmBackendWeb.AuthTestSupport

  @secret "Handover-Temporary-Secret!42"

  setup do
    originals =
      Map.new([:credential_vault, :mailbox_lab_domain], fn key ->
        {key, Application.get_env(:itsm_backend, key)}
      end)

    Application.put_env(:itsm_backend, :credential_vault,
      key_b64: Base.encode64(:crypto.strong_rand_bytes(32)),
      key_version: "handover-test-v1",
      ttl_seconds: 3_600
    )

    Application.put_env(:itsm_backend, :mailbox_lab_domain, "handover-lab.test")
    SignInGuard.reset()

    on_exit(fn ->
      SignInGuard.reset()

      Enum.each(originals, fn
        {key, nil} -> Application.delete_env(:itsm_backend, key)
        {key, value} -> Application.put_env(:itsm_backend, key, value)
      end)
    end)

    %{identity: identity()}
  end

  test "the requester reveals a new account's temporary password once", %{identity: id} do
    credential = account_credential()
    job = completed_job(id, "account_create", credential)

    response = reveal(id, job, credential, id.password)
    body = json_response(response, 200)

    assert body == %{
             "credential_id" => credential,
             "subject" => body["subject"],
             "temporary_password" => @secret,
             "must_change_at_first_sign_in" => true
           }

    assert body["subject"]["kind"] == "directory_account"
    assert is_binary(body["subject"]["user_id"])
    assert get_resp_header(response, "cache-control") == ["no-store"]

    assert reveal(id, job, credential, id.password) |> json_response(410) == %{
             "error" => "credential_already_revealed"
           }

    stored = stored_credential(credential)
    assert stored["consumed_by"] == id.user["user_id"]
    assert stored["consumed_at"] != nil
    refute Map.has_key?(stored, "ciphertext_b64")
    refute inspect(stored) =~ @secret
  end

  test "a password reset and a new mailbox are handed over the same way", %{identity: id} do
    reset = reset_credential()
    mailbox = mailbox_credential()

    for {tool, credential, kind} <- [
          {"reset_password", reset, "directory_account"},
          {"mailbox_create", mailbox, "mailbox"}
        ] do
      job = completed_job(id, tool, credential)
      body = reveal(id, job, credential, id.password) |> json_response(200)
      assert body["temporary_password"] == @secret
      assert body["subject"]["kind"] == kind
    end
  end

  test "only the owner of the request, with their own password, can reveal it", %{identity: id} do
    credential = account_credential()
    job = completed_job(id, "account_create", credential)
    other = identity()

    assert reveal(other, job, credential, other.password) |> json_response(403) == %{
             "error" => "forbidden"
           }

    assert reveal(id, job, credential, "not the password") |> json_response(401) == %{
             "error" => "invalid_credentials"
           }

    assert reveal(id, job, credential, id.password) |> json_response(200)
  end

  test "wrong passwords count against the sign-in limit", %{identity: id} do
    credential = account_credential()
    job = completed_job(id, "account_create", credential)
    limit = ItsmBackend.RuntimeConfig.sign_in_guard!().account_failures

    for _ <- 1..limit do
      assert reveal(id, job, credential, "not the password") |> json_response(401)
    end

    assert (reveal(id, job, credential, id.password) |> json_response(429))["error"] ==
             "sign_in_rate_limited"

    assert stored_credential(credential)["consumed_at"] == nil
  end

  test "a credential the approved result does not name is refused", %{identity: id} do
    named = account_credential()
    unnamed = account_credential()
    job = completed_job(id, "account_create", named)

    assert reveal(id, job, unnamed, id.password) |> json_response(404) == %{
             "error" => "credential_not_found"
           }

    assert stored_credential(unnamed)["consumed_at"] == nil
  end

  test "an unfinished, failed or rejected request reveals nothing", %{identity: id} do
    credential = account_credential()

    for {status, execution, approval} <- [
          {"failed", "failed", "failed"},
          {"denied", "rejected", "rejected"}
        ] do
      job = completed_job(id, "account_create", credential, status, execution, approval)

      assert reveal(id, job, credential, id.password) |> json_response(404) == %{
               "error" => "credential_not_found"
             }
    end

    assert stored_credential(credential)["consumed_at"] == nil
  end

  test "concurrent reveals hand the password over exactly once", %{identity: id} do
    credential = account_credential()
    job = completed_job(id, "account_create", credential)

    outcomes =
      1..6
      |> Task.async_stream(
        fn _ -> ItsmBackend.CredentialHandover.reveal(id.user, job.id, credential) end,
        max_concurrency: 6
      )
      |> Enum.map(fn {:ok, outcome} -> outcome end)

    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
  end

  test "an expired credential is refused and stays sealed", %{identity: id} do
    credential = account_credential()
    job = completed_job(id, "account_create", credential)

    {:ok, _} =
      Surreal.query(
        "UPDATE type::record('credential_secret', $id) SET expires_at = time::now() - 1m;",
        %{"id" => credential}
      )

    assert reveal(id, job, credential, id.password) |> json_response(410) == %{
             "error" => "credential_expired"
           }

    assert stored_credential(credential)["ciphertext_b64"]
  end

  test "a ciphertext moved to another identity does not decrypt", %{identity: id} do
    credential = account_credential()
    job = completed_job(id, "account_create", credential)

    {:ok, _} =
      Surreal.query(
        "UPDATE type::record('credential_secret', $id) SET directory_user_id = 'someone.else';",
        %{"id" => credential}
      )

    assert reveal(id, job, credential, id.password) |> json_response(409) == %{
             "error" => "credential_unreadable"
           }

    assert stored_credential(credential)["consumed_at"] == nil
  end

  test "a chat's history marks the turn whose approved action saved a temporary password",
       %{identity: id} do
    credential = account_credential()
    job = completed_job(id, "account_create", credential)

    failed =
      completed_job(id, "account_create", account_credential(), "failed", "failed", "failed")

    turns =
      auth_conn(id)
      |> get("/api/v2/chats/#{id.chat["chat_id"]}/history")
      |> json_response(200)
      |> Map.fetch!("messages")
      |> Enum.filter(&(&1["role"] == "assistant"))

    assert Enum.find(turns, &(&1["job_id"] == job.id))["credential_handover"] == %{
             "credential_id" => credential
           }

    refute Map.has_key?(Enum.find(turns, &(&1["job_id"] == failed.id)), "credential_handover")
    refute inspect(turns) =~ @secret

    {:ok, _} = ItsmBackend.CredentialHandover.reveal(id.user, job.id, credential)

    revealed =
      auth_conn(id)
      |> get("/api/v2/chats/#{id.chat["chat_id"]}/history")
      |> json_response(200)
      |> Map.fetch!("messages")
      |> Enum.find(&(&1["role"] == "assistant" and &1["job_id"] == job.id))

    assert revealed["credential_handover"] == %{"credential_id" => credential}
  end

  test "an onboarding account's password stays revealable after its ticket step",
       %{identity: id} do
    for {status, ticket} <- [{"completed", "succeeded"}, {"failed", "failed"}] do
      credential = account_credential()
      job = onboarding_job(id, credential, status, ticket)

      [turn] =
        auth_conn(id)
        |> get("/api/v2/chats/#{id.chat["chat_id"]}/history")
        |> json_response(200)
        |> Map.fetch!("messages")
        |> Enum.filter(&(&1["role"] == "assistant" and &1["job_id"] == job.id))

      assert turn["credential_handover"] == %{"credential_id" => credential}
      assert reveal(id, job, credential, id.password) |> json_response(200)
    end
  end

  test "a failed account step offers nothing, even in the approval history", %{identity: id} do
    credential = account_credential()
    job = onboarding_job(id, credential, "failed", "failed", "failed")

    assert ItsmBackend.CredentialHandover.offered_credentials(job) == []

    assert reveal(id, job, credential, id.password) |> json_response(404) == %{
             "error" => "credential_not_found"
           }
  end

  test "a malformed credential id in a result is never offered", %{identity: id} do
    job = completed_job(id, "account_create", "not-a-credential-id")

    assert ItsmBackend.CredentialHandover.offered_credentials(job) == []

    [turn] =
      auth_conn(id)
      |> get("/api/v2/chats/#{id.chat["chat_id"]}/history")
      |> json_response(200)
      |> Map.fetch!("messages")
      |> Enum.filter(&(&1["role"] == "assistant" and &1["job_id"] == job.id))

    refute Map.has_key?(turn, "credential_handover")
  end

  test "reveal needs a session and CSRF and accepts only the password", %{identity: id} do
    credential = account_credential()
    job = completed_job(id, "account_create", credential)
    path = reveal_path(job, credential)

    assert build_conn() |> post(path, %{"password" => id.password}) |> json_response(401)

    cookie_conn =
      build_conn()
      |> put_req_cookie(ItsmBackend.RuntimeConfig.auth!().cookie_name, id.auth.raw_token)

    assert cookie_conn |> post(path, %{"password" => id.password}) |> json_response(403) == %{
             "error" => "csrf_failed"
           }

    assert auth_conn(id) |> post(path, %{}) |> json_response(422) == %{
             "error" => "invalid_request"
           }

    assert stored_credential(credential)["consumed_at"] == nil
  end

  defp identity do
    suffix = 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    password = "correct horse battery #{suffix}!"

    {:ok, _pending, token, _verification} =
      ItsmBackend.Auth.register(%{
        "email" => "handover-#{suffix}@example.test",
        "display_name" => "Handover #{suffix}",
        "password" => password
      })

    {:ok, user} = ItsmBackend.Auth.verify_email(token)
    {:ok, auth} = ItsmBackend.Auth.login("handover-#{suffix}@example.test", password, "ExUnit")
    {:ok, chat} = ItsmBackend.Chats.create(user, %{"title" => "Handover #{suffix}"})
    %{user: user, auth: auth, chat: chat, password: password}
  end

  defp account_credential do
    user_id = "handover#{System.unique_integer([:positive])}"

    {:ok, result} =
      ProvisionedAccounts.persist(%{
        "directory_user_id" => user_id,
        "email" => "#{user_id}@itsm.test",
        "given_name" => "Hand",
        "family_name" => "Over",
        "temporary_password" => @secret
      })

    result["credential_id"]
  end

  defp reset_credential do
    {:ok, result} =
      DirectoryCredentials.persist(%{
        "directory_user_id" => "reset#{System.unique_integer([:positive])}",
        "temporary_password" => @secret
      })

    result["credential_id"]
  end

  defp mailbox_credential do
    {:ok, result} =
      ProvisionedMailboxes.persist(%{
        "provider" => "maddy",
        "email" => "box#{System.unique_integer([:positive])}@handover-lab.test",
        "temporary_password" => @secret,
        "verification" => %{"smtp" => true, "imap" => true}
      })

    result["credential_id"]
  end

  defp completed_job(
         id,
         tool,
         credential,
         status \\ "completed",
         execution \\ "succeeded",
         approval \\ "approved"
       ) do
    {:ok, job} =
      Jobs.create(%{
        user_id: id.user["user_id"],
        conversation_id: id.chat["chat_id"],
        message: "Hand over fixture"
      })

    {:ok, processing} = Job.claim(job, 60)
    {:ok, waiting} = Job.transition(processing, "waiting_approval")
    {:ok, finished} = Job.transition(waiting, status)

    # Every fixture names the credential, so only the request's own state decides.
    result = %{
      "ok" => execution == "succeeded",
      "status" => "executed",
      "credential_id" => credential
    }

    finished
    |> Job.put_ai_metadata(
      selected_agent: "account-specialist",
      proposed_tool: %{"tool" => tool, "arguments" => %{}, "approval_id" => "approval-handover"}
    )
    |> Job.put_result(%{
      "answer" => "Done.",
      "approval_execution" => %{
        "approval_id" => "approval-handover",
        "protocol_status" => "processed",
        "execution_status" => execution,
        "approval_status" => approval,
        "replayed" => false,
        "result" => result,
        "error" => nil
      }
    })
    |> Jobs.update()
    |> then(fn {:ok, stored} -> stored end)
  end

  # The account step is kept in the approval history; the ticket step is the
  # request's latest outcome.
  defp onboarding_job(id, credential, status, ticket, account \\ "succeeded") do
    job = completed_job(id, "ticket_create", credential, status, ticket, approval_of(ticket))

    account_step = %{
      "approval_id" => "approval-account",
      "protocol_status" => "processed",
      "execution_status" => account,
      "approval_status" => approval_of(account),
      "replayed" => false,
      "result" => %{"ok" => account == "succeeded", "credential_id" => credential},
      "error" => nil
    }

    ticket_step =
      put_in(job.result, ["approval_execution", "result"], %{"ok" => ticket == "succeeded"})

    job
    |> Job.put_result(
      Map.put(ticket_step, "approval_history", [
        %{"proposal" => %{"tool" => "account_create"}, "execution" => account_step}
      ])
    )
    |> Jobs.update()
    |> then(fn {:ok, stored} -> stored end)
  end

  defp approval_of("succeeded"), do: "approved"
  defp approval_of(status), do: status

  defp stored_credential(credential) do
    {:ok, [%{"status" => "OK", "result" => record}]} =
      Surreal.query("SELECT * FROM ONLY type::record('credential_secret', $id);", %{
        "id" => credential
      })

    record
  end

  defp reveal_path(job, credential), do: "/api/v2/jobs/#{job.id}/credentials/#{credential}/reveal"

  defp auth_conn(id), do: build_conn() |> AuthTestSupport.bearer_conn(id.auth.raw_token)

  defp reveal(id, job, credential, password) do
    auth_conn(id) |> post(reveal_path(job, credential), %{"password" => password})
  end
end
