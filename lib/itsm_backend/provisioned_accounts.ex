defmodule ItsmBackend.ProvisionedAccounts do
  @moduledoc """
  Durable persistence boundary for successfully provisioned corporate
  identities and their encrypted temporary credentials.

  This module never returns or persists the plaintext credential.
  """

  alias ItsmBackend.ProvisionedAccounts.Cipher
  alias ItsmBackend.ProvisionedAccounts.SurrealStore
  alias ItsmBackend.RuntimeConfig

  @spec persist(map()) :: {:ok, map()} | {:error, term()}
  def persist(attrs) when is_map(attrs) do
    with {:ok, directory_user_id} <- required(attrs, "directory_user_id", 128),
         {:ok, email} <- required(attrs, "email", 320),
         {:ok, given_name} <- required(attrs, "given_name", 128),
         {:ok, family_name} <- required(attrs, "family_name", 128),
         {:ok, department} <- optional(attrs, "department", 200),
         {:ok, role} <- optional(attrs, "role", 200),
         {:ok, temporary_password} <- secret(attrs),
         {:ok, vault} <- credential_vault(),
         {:ok, records} <- build_records(
           directory_user_id,
           email,
           given_name,
           family_name,
           department,
           role,
           temporary_password,
           vault
         ),
         :ok <- SurrealStore.create(records.account, records.credential) do
      {:ok,
       %{
         "account_record_id" => records.account["account_record_id"],
         "credential_id" => records.credential["credential_id"],
         "directory_user_id" => directory_user_id,
         "email" => email,
         "credential_expires_at" => records.credential["expires_at"]
       }}
    end
  end

  def persist(_attrs), do: {:error, :invalid_payload}

  defp build_records(
         directory_user_id,
         email,
         given_name,
         family_name,
         department,
         role,
         temporary_password,
         vault
       ) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = DateTime.add(now, vault.ttl_seconds, :second)
    account_id = generate_id()
    credential_id = generate_id()

    aad =
      [
        "credential-secret.v1",
        credential_id,
        directory_user_id,
        email,
        vault.key_version
      ]
      |> Enum.join("|")

    with {:ok, encrypted} <- Cipher.encrypt(temporary_password, vault.key, aad) do
      account = %{
        "account_record_id" => account_id,
        "directory_user_id" => directory_user_id,
        "email" => email,
        "given_name" => given_name,
        "family_name" => family_name,
        "department" => department,
        "role" => role,
        "credential_id" => credential_id,
        "status" => "provisioned",
        "created_at" => DateTime.to_iso8601(now)
      }

      credential = %{
        "credential_id" => credential_id,
        "subject_type" => "directory_account",
        "directory_user_id" => directory_user_id,
        "email" => email,
        "kind" => "temporary_password",
        "algorithm" => encrypted["algorithm"],
        "key_version" => vault.key_version,
        "iv_b64" => encrypted["iv_b64"],
        "ciphertext_b64" => encrypted["ciphertext_b64"],
        "tag_b64" => encrypted["tag_b64"],
        "aad" => encrypted["aad"],
        "created_at" => DateTime.to_iso8601(now),
        "expires_at" => DateTime.to_iso8601(expires_at),
        "consumed_at" => nil
      }

      {:ok, %{account: account, credential: credential}}
    end
  end

  defp credential_vault do
    try do
      {:ok, RuntimeConfig.credential_vault!()}
    rescue
      error in RuntimeConfig.Error ->
        {:error, {:credential_vault_configuration, error.message}}
    end
  end

  defp required(attrs, key, max_length) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        if value == String.trim(value) and value != "" and String.length(value) <= max_length do
          {:ok, value}
        else
          {:error, {:invalid_field, key}}
        end

      _ ->
        {:error, {:invalid_field, key}}
    end
  end

  defp optional(attrs, key, max_length) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> required(attrs, key, max_length)
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp secret(attrs) do
    case Map.get(attrs, "temporary_password") do
      value when is_binary(value) ->
        cond do
          value == "" -> {:error, {:invalid_field, "temporary_password"}}
          String.length(value) < 16 -> {:error, {:invalid_field, "temporary_password"}}
          String.length(value) > 256 -> {:error, {:invalid_field, "temporary_password"}}
          true -> {:ok, value}
        end

      _ ->
        {:error, {:invalid_field, "temporary_password"}}
    end
  end

  defp generate_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
