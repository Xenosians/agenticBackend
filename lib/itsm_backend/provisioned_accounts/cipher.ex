defmodule ItsmBackend.ProvisionedAccounts.Cipher do
  @moduledoc """
  AES-256-GCM encryption for temporary account credentials.

  The encryption key is supplied by RuntimeConfig and is never stored
  with the ciphertext. The authenticated-data string binds ciphertext
  to the provisioned identity metadata that Phoenix persists.
  """

  @iv_bytes 12

  @spec encrypt(
          String.t(),
          binary(),
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def encrypt(secret, key, aad)
      when is_binary(secret) and
             is_binary(key) and
             byte_size(key) == 32 and
             is_binary(aad) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        iv,
        secret,
        aad,
        true
      )

    {:ok,
     %{
       "algorithm" => "AES-256-GCM",
       "iv_b64" => Base.encode64(iv),
       "ciphertext_b64" => Base.encode64(ciphertext),
       "tag_b64" => Base.encode64(tag),
       "aad" => aad
     }}
  rescue
    error ->
      {:error, {:credential_encryption_failed, error}}
  end

  def encrypt(_secret, _key, _aad) do
    {:error, :invalid_encryption_input}
  end
end
