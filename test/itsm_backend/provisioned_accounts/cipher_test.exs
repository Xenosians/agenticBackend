defmodule ItsmBackend.ProvisionedAccounts.CipherTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.ProvisionedAccounts.Cipher

  test "AES-GCM encryption round-trips without exposing plaintext" do
    key = :crypto.strong_rand_bytes(32)
    secret = "A-very-secret-temporary-password!42"
    aad = "credential-secret.v1|cred|user|user@example.com|v1"

    assert {:ok, encrypted} = Cipher.encrypt(secret, key, aad)
    refute encrypted["ciphertext_b64"] =~ secret

    iv = Base.decode64!(encrypted["iv_b64"])
    ciphertext = Base.decode64!(encrypted["ciphertext_b64"])
    tag = Base.decode64!(encrypted["tag_b64"])

    assert :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             aad,
             tag,
             false
           ) == secret
  end
end
