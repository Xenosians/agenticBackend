defmodule ItsmBackend.RuntimeConfigCredentialVaultTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.RuntimeConfig

  setup do
    original = Application.get_env(:itsm_backend, :credential_vault)

    on_exit(fn ->
      if original == nil do
        Application.delete_env(:itsm_backend, :credential_vault)
      else
        Application.put_env(:itsm_backend, :credential_vault, original)
      end
    end)

    :ok
  end

  test "returns a validated 32-byte credential encryption key" do
    key = :crypto.strong_rand_bytes(32)

    Application.put_env(
      :itsm_backend,
      :credential_vault,
      key_b64: Base.encode64(key),
      key_version: "test-v1",
      ttl_seconds: 3_600
    )

    assert RuntimeConfig.credential_vault!() == %{
             key: key,
             key_version: "test-v1",
             ttl_seconds: 3_600
           }
  end

  test "rejects a credential encryption key that is not 32 bytes" do
    Application.put_env(
      :itsm_backend,
      :credential_vault,
      key_b64: Base.encode64(:crypto.strong_rand_bytes(16)),
      key_version: "test-v1",
      ttl_seconds: 3_600
    )

    assert_raise RuntimeConfig.Error, ~r/32 bytes/, fn ->
      RuntimeConfig.credential_vault!()
    end
  end

  test "rejects malformed base64 credential encryption key" do
    Application.put_env(
      :itsm_backend,
      :credential_vault,
      key_b64: "not-base64!",
      key_version: "test-v1",
      ttl_seconds: 3_600
    )

    assert_raise RuntimeConfig.Error, ~r/base64/, fn ->
      RuntimeConfig.credential_vault!()
    end
  end
end
