defmodule ItsmBackend.ProvisionedMailboxesTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.ProvisionedMailboxes
  alias ItsmBackend.RuntimeConfig
  alias ItsmBackend.Surreal

  setup do
    original_vault = Application.get_env(:itsm_backend, :credential_vault)
    original_domain = Application.get_env(:itsm_backend, :mailbox_lab_domain)
    key = :crypto.strong_rand_bytes(32)

    Application.put_env(:itsm_backend, :credential_vault,
      key_b64: Base.encode64(key),
      key_version: "mailbox-test-v1",
      ttl_seconds: 3_600
    )

    Application.put_env(:itsm_backend, :mailbox_lab_domain, "mailbox-lab.test")

    on_exit(fn ->
      restore_env(:credential_vault, original_vault)
      restore_env(:mailbox_lab_domain, original_domain)
    end)

    %{key: key}
  end

  test "persists a distinct mailbox subject with decryptable encrypted credentials and exact expiry",
       %{key: key} do
    attrs = valid_attrs()
    assert {:ok, result} = ProvisionedMailboxes.persist(attrs)
    assert result["status"] == "provisioned_unverified"
    assert result["verification"] == %{"smtp" => false, "imap" => false}
    refute Map.has_key?(result, "temporary_password")
    refute Map.has_key?(result, "directory_user_id")

    mailbox = read_record("provisioned_mailbox", result["mailbox_record_id"])
    credential = read_record("credential_secret", result["credential_id"])
    assert mailbox["email"] == attrs["email"]
    assert credential["subject_type"] == "mailbox"
    assert credential["mailbox_record_id"] == result["mailbox_record_id"]
    refute Map.has_key?(credential, "directory_user_id")

    refute Jason.encode!(%{result: result, mailbox: mailbox, credential: credential}) =~
             attrs["temporary_password"]

    assert :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             Base.decode64!(credential["iv_b64"]),
             Base.decode64!(credential["ciphertext_b64"]),
             credential["aad"],
             Base.decode64!(credential["tag_b64"]),
             false
           ) == attrs["temporary_password"]

    assert {:ok, created_at, _} = DateTime.from_iso8601(credential["created_at"])
    assert {:ok, expires_at, _} = DateTime.from_iso8601(credential["expires_at"])
    assert DateTime.diff(expires_at, created_at, :second) == 3_600
    assert result["credential_expires_at"] == credential["expires_at"]
    assert credential["consumed_at"] == nil
  end

  test "both protocol flags are required before labeling a saved mailbox verified" do
    for verification <- [%{"smtp" => true, "imap" => false}, %{"smtp" => false, "imap" => true}] do
      assert {:ok, result} =
               ProvisionedMailboxes.persist(Map.put(valid_attrs(), "verification", verification))

      assert result["status"] == "provisioned_unverified"
    end

    assert {:ok, result} =
             ProvisionedMailboxes.persist(
               Map.put(valid_attrs(), "verification", %{"smtp" => true, "imap" => true})
             )

    assert result["status"] == "provisioned_verified"
  end

  test "duplicate email cannot overwrite the mailbox or encrypted password" do
    attrs = valid_attrs()
    assert {:ok, first} = ProvisionedMailboxes.persist(attrs)
    credential_before = read_record("credential_secret", first["credential_id"])

    assert {:error, :mailbox_already_persisted} =
             ProvisionedMailboxes.persist(
               Map.put(attrs, "temporary_password", "Different-Temporary-Password!42")
             )

    assert read_record("credential_secret", first["credential_id"]) == credential_before
  end

  test "validates provider and exact lab email without normalizing untrusted addresses" do
    assert {:error, {:invalid_field, "provider"}} =
             ProvisionedMailboxes.persist(Map.put(valid_attrs(), "provider", "directory"))

    for email <- [
          "User@mailbox-lab.test",
          "user@other.test",
          "user@example.com",
          "a..b@mailbox-lab.test",
          ".user@mailbox-lab.test",
          "user.@mailbox-lab.test",
          "user@mailbox-lab.test\n",
          "a+b@mailbox-lab.test"
        ] do
      assert {:error, {:invalid_field, "email"}} =
               ProvisionedMailboxes.persist(Map.put(valid_attrs(), "email", email))
    end
  end

  test "concurrent provisioning callbacks cannot create orphan or duplicate credentials" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.ConcurrentTasks})
    attrs = valid_attrs()

    results =
      1..4
      |> Enum.map(fn _ ->
        Task.Supervisor.async_nolink(supervisor, fn -> ProvisionedMailboxes.persist(attrs) end)
      end)
      |> Task.await_many()

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :mailbox_already_persisted})) == 3

    assert {:ok, [%{"result" => [mailbox]}]} =
             Surreal.query(
               "SELECT * FROM provisioned_mailbox WHERE email = $email;",
               Map.take(attrs, ["email"])
             )

    assert {:ok, [%{"result" => [credential]}]} =
             Surreal.query(
               "SELECT * FROM credential_secret WHERE email = $email;",
               Map.take(attrs, ["email"])
             )

    assert mailbox["credential_id"] == credential["credential_id"]
  end

  test "the mailbox schema can be initialized repeatedly" do
    schema = File.read!(Path.expand("../../priv/surreal/schema.surql", __DIR__))
    assert {:ok, _} = Surreal.query(schema)
    assert {:ok, _} = Surreal.query(schema)
  end

  test "rejects malformed password and evidence instead of persisting arbitrary fields" do
    for password <- [nil, "short", String.duplicate("a", 257), "Password-with-newline\n42"] do
      assert {:error, {:invalid_field, "temporary_password"}} =
               ProvisionedMailboxes.persist(
                 Map.put(valid_attrs(), "temporary_password", password)
               )
    end

    for evidence <- [
          nil,
          %{"smtp" => "true", "imap" => true},
          %{"smtp" => true},
          %{"smtp" => true, "imap" => true, "password" => "secret"}
        ] do
      assert {:error, {:invalid_field, "verification"}} =
               ProvisionedMailboxes.persist(Map.put(valid_attrs(), "verification", evidence))
    end

    assert {:error, :invalid_payload} =
             ProvisionedMailboxes.persist(Map.put(valid_attrs(), "directory_user_id", "invented"))

    assert {:error, :invalid_payload} =
             ProvisionedMailboxes.persist(Map.delete(valid_attrs(), "temporary_password"))

    assert {:error, :invalid_payload} = ProvisionedMailboxes.persist(nil)
  end

  test "requires a valid lab domain and vault before writing" do
    Application.put_env(:itsm_backend, :mailbox_lab_domain, "example.com")
    assert_raise RuntimeConfig.Error, fn -> RuntimeConfig.mailbox_lab_domain!() end
    assert {:error, :mailbox_lab_configuration} = ProvisionedMailboxes.persist(valid_attrs())

    Application.put_env(:itsm_backend, :mailbox_lab_domain, "mailbox-lab.test")
    Application.delete_env(:itsm_backend, :credential_vault)
    assert {:error, :credential_vault_configuration} = ProvisionedMailboxes.persist(valid_attrs())
  end

  test "Phoenix parameter filtering covers temporary mailbox passwords" do
    attrs = valid_attrs()
    assert Phoenix.Logger.filter_values(attrs)["temporary_password"] == "[FILTERED]"
    refute inspect(Phoenix.Logger.filter_values(attrs)) =~ attrs["temporary_password"]
  end

  defp valid_attrs do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    %{
      "provider" => "maddy",
      "email" => "mailboxtest#{suffix}@mailbox-lab.test",
      "temporary_password" => "Mailbox-Temporary-Secret!42",
      "verification" => %{"smtp" => false, "imap" => false}
    }
  end

  defp read_record(table, id) do
    assert {:ok, [%{"result" => result}]} =
             Surreal.query("SELECT * FROM ONLY type::record($table, $id);", %{
               "table" => table,
               "id" => id
             })

    result
  end

  defp restore_env(key, nil), do: Application.delete_env(:itsm_backend, key)
  defp restore_env(key, value), do: Application.put_env(:itsm_backend, key, value)
end
