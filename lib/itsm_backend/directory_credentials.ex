defmodule ItsmBackend.DirectoryCredentials do
  @moduledoc """
  Encrypted temporary credentials issued for an existing directory account,
  for example by an approved password reset.

  Only the AI service's trusted reset path calls this boundary. It stores the
  credential encrypted; it never returns the plaintext and exposes no
  retrieval route.
  """

  alias ItsmBackend.ProvisionedAccounts.Cipher
  alias ItsmBackend.RuntimeConfig
  alias ItsmBackend.Surreal

  @fields ~w(directory_user_id temporary_password)

  @spec persist(map()) :: {:ok, map()} | {:error, term()}
  def persist(attrs) when is_map(attrs) do
    with :ok <- validate_fields(attrs),
         {:ok, user_id} <- user_id(attrs["directory_user_id"]),
         :ok <- validate_password(attrs["temporary_password"]),
         {:ok, vault} <- credential_vault(),
         {:ok, credential} <- build_credential(user_id, attrs["temporary_password"], vault),
         :ok <- store(credential) do
      {:ok,
       %{
         "credential_id" => credential["credential_id"],
         "directory_user_id" => user_id,
         "credential_expires_at" => credential["expires_at"]
       }}
    end
  end

  def persist(_attrs), do: {:error, :invalid_payload}

  defp build_credential(user_id, password, vault) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    credential_id = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    aad =
      Enum.join(
        ["credential-secret.v1", credential_id, "directory_account", user_id, vault.key_version],
        "|"
      )

    with {:ok, encrypted} <- Cipher.encrypt(password, vault.key, aad) do
      {:ok,
       Map.merge(encrypted, %{
         "credential_id" => credential_id,
         "subject_type" => "directory_account",
         "directory_user_id" => user_id,
         "kind" => "temporary_password",
         "issued_by" => "password_reset",
         "key_version" => vault.key_version,
         "created_at" => DateTime.to_iso8601(now),
         "expires_at" => now |> DateTime.add(vault.ttl_seconds, :second) |> DateTime.to_iso8601(),
         "consumed_at" => nil
       })}
    end
  end

  defp store(credential) do
    statement = """
    CREATE ONLY type::record('credential_secret', $credential_id) CONTENT $credential;
    """

    params = %{"credential_id" => credential["credential_id"], "credential" => credential}

    case Surreal.query(statement, params) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :credential_persistence_failed}
    end
  end

  defp validate_fields(attrs) do
    if Enum.sort(Map.keys(attrs)) == Enum.sort(@fields), do: :ok, else: {:error, :invalid_payload}
  end

  defp user_id(value) when is_binary(value) do
    if value != "" and value == String.trim(value) and String.length(value) <= 128 and
         not String.contains?(value, ["\r", "\n", <<0>>]) do
      {:ok, value}
    else
      {:error, {:invalid_field, "directory_user_id"}}
    end
  end

  defp user_id(_), do: {:error, {:invalid_field, "directory_user_id"}}

  defp validate_password(password) when is_binary(password) do
    if String.length(password) in 16..256 and not String.contains?(password, ["\r", "\n", <<0>>]),
      do: :ok,
      else: {:error, {:invalid_field, "temporary_password"}}
  end

  defp validate_password(_), do: {:error, {:invalid_field, "temporary_password"}}

  defp credential_vault do
    {:ok, RuntimeConfig.credential_vault!()}
  rescue
    RuntimeConfig.Error -> {:error, :credential_vault_configuration}
  end
end
