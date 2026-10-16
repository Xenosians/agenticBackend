defmodule ItsmBackend.ProvisionedMailboxes do
  @moduledoc """
  Durable metadata and encrypted credential boundary for the local mail lab.

  This records an already provisioned mailbox; it does not create a directory
  identity, deliver mail, or expose a credential retrieval API. Verification is
  explicit so saving a credential never implies SMTP or IMAP succeeded.
  """

  alias ItsmBackend.ProvisionedAccounts.Cipher
  alias ItsmBackend.ProvisionedMailboxes.SurrealStore
  alias ItsmBackend.RuntimeConfig

  @fields ~w(provider email temporary_password verification)
  @local_part ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/

  @spec persist(map()) :: {:ok, map()} | {:error, term()}
  def persist(attrs) when is_map(attrs) do
    with :ok <- validate_fields(attrs),
         :ok <- validate_provider(attrs["provider"]),
         {:ok, domain} <- lab_domain(),
         :ok <- validate_email(attrs["email"], domain),
         :ok <- validate_password(attrs["temporary_password"]),
         :ok <- validate_verification(attrs["verification"]),
         {:ok, vault} <- credential_vault(),
         {:ok, records} <- build_records(attrs, vault),
         :ok <- SurrealStore.create(records.mailbox, records.credential) do
      {:ok,
       Map.take(records.mailbox, ~w(mailbox_record_id provider email status verification))
       |> Map.merge(%{
         "credential_id" => records.credential["credential_id"],
         "credential_expires_at" => records.credential["expires_at"]
       })}
    end
  end

  def persist(_attrs), do: {:error, :invalid_payload}

  defp build_records(attrs, vault) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = DateTime.add(now, vault.ttl_seconds, :second)
    mailbox_id = generate_id()
    credential_id = generate_id()
    provider = attrs["provider"]
    email = attrs["email"]
    verification = attrs["verification"]
    verified? = verification["smtp"] and verification["imap"]

    aad =
      Enum.join(
        [
          "credential-secret.v1",
          credential_id,
          "mailbox",
          mailbox_id,
          provider,
          email,
          vault.key_version
        ],
        "|"
      )

    with {:ok, encrypted} <- Cipher.encrypt(attrs["temporary_password"], vault.key, aad) do
      mailbox = %{
        "mailbox_record_id" => mailbox_id,
        "provider" => provider,
        "email" => email,
        "credential_id" => credential_id,
        "status" => if(verified?, do: "provisioned_verified", else: "provisioned_unverified"),
        "verification" => verification,
        "created_at" => DateTime.to_iso8601(now)
      }

      credential =
        Map.merge(encrypted, %{
          "credential_id" => credential_id,
          "subject_type" => "mailbox",
          "mailbox_record_id" => mailbox_id,
          "provider" => provider,
          "email" => email,
          "kind" => "temporary_password",
          "key_version" => vault.key_version,
          "created_at" => DateTime.to_iso8601(now),
          "expires_at" => DateTime.to_iso8601(expires_at),
          "consumed_at" => nil
        })

      {:ok, %{mailbox: mailbox, credential: credential}}
    end
  end

  defp validate_fields(attrs) do
    if Enum.sort(Map.keys(attrs)) == Enum.sort(@fields),
      do: :ok,
      else: {:error, :invalid_payload}
  end

  defp validate_provider("maddy"), do: :ok
  defp validate_provider(_), do: {:error, {:invalid_field, "provider"}}

  defp validate_email(email, domain) when is_binary(email) do
    case String.split(email, "@") do
      [local, ^domain] ->
        if Regex.match?(@local_part, local) and not String.contains?(local, "..") and
             not String.ends_with?(local, ".") do
          :ok
        else
          {:error, {:invalid_field, "email"}}
        end

      _ ->
        {:error, {:invalid_field, "email"}}
    end
  end

  defp validate_email(_, _), do: {:error, {:invalid_field, "email"}}

  defp validate_password(password) when is_binary(password) do
    if String.length(password) in 16..256 and not String.contains?(password, ["\r", "\n", <<0>>]),
      do: :ok,
      else: {:error, {:invalid_field, "temporary_password"}}
  end

  defp validate_password(_), do: {:error, {:invalid_field, "temporary_password"}}

  defp validate_verification(%{"smtp" => smtp, "imap" => imap} = verification)
       when is_boolean(smtp) and is_boolean(imap) and map_size(verification) == 2,
       do: :ok

  defp validate_verification(_), do: {:error, {:invalid_field, "verification"}}

  defp lab_domain do
    {:ok, RuntimeConfig.mailbox_lab_domain!()}
  rescue
    RuntimeConfig.Error -> {:error, :mailbox_lab_configuration}
  end

  defp credential_vault do
    {:ok, RuntimeConfig.credential_vault!()}
  rescue
    RuntimeConfig.Error -> {:error, :credential_vault_configuration}
  end

  defp generate_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
