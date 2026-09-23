defmodule ItsmBackend.ProvisionedAccounts.SurrealStoreTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.ProvisionedAccounts
  alias ItsmBackend.Surreal

  setup do
    original = Application.get_env(:itsm_backend, :credential_vault)

    Application.put_env(
      :itsm_backend,
      :credential_vault,
      key_b64: Base.encode64(:crypto.strong_rand_bytes(32)),
      key_version: "test-v1",
      ttl_seconds: 3_600
    )

    on_exit(fn ->
      if original == nil do
        Application.delete_env(:itsm_backend, :credential_vault)
      else
        Application.put_env(:itsm_backend, :credential_vault, original)
      end
    end)

    :ok
  end

  test "persists account identity and encrypted credential without plaintext" do
    secret = "Temporary-Test-Password!42"
    suffix = System.unique_integer([:positive])
    user_id = "accttest#{suffix}"
    email = "#{user_id}@example.test"

    assert {:ok, result} =
             ProvisionedAccounts.persist(%{
               "directory_user_id" => user_id,
               "email" => email,
               "given_name" => "Test",
               "family_name" => "User",
               "department" => "Engineering",
               "role" => "Engineer",
               "temporary_password" => secret
             })

    assert is_binary(result["account_record_id"])
    assert is_binary(result["credential_id"])
    refute Map.has_key?(result, "temporary_password")

    statement = """
    SELECT * FROM ONLY type::record($table, $id);
    """

    assert {:ok, credential_response} =
             Surreal.query(statement, %{
               "table" => "credential_secret",
               "id" => result["credential_id"]
             })

    serialized = inspect(credential_response)
    refute serialized =~ secret
    assert serialized =~ "ciphertext_b64"
    assert serialized =~ email
  end
end
