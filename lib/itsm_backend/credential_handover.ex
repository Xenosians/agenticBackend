defmodule ItsmBackend.CredentialHandover do
  @moduledoc """
  One-time hand-over of a temporary password to the person who asked for it.

  A new account's own mailbox does not exist yet, so its first password is
  never mailed to it. The owner of the approved request reveals the temporary
  password once inside Janus and hands it over; the person changes it at first
  sign-in.

  Authorization comes only from Phoenix's own records: the request belongs to
  the signed-in user and an approval outcome Phoenix recorded for it as
  approved and succeeded names this credential. The ciphertext's authenticated
  data is rebuilt from the stored identity, so a ciphertext moved to another
  record does not decrypt. A single conditional update marks the credential
  consumed and erases the ciphertext, so a second reveal, or a racing one,
  finds nothing to decrypt.
  """

  alias ItsmBackend.Auth.Authorization
  alias ItsmBackend.Jobs
  alias ItsmBackend.RuntimeConfig
  alias ItsmBackend.Surreal

  @aad_version "credential-secret.v1"
  @credential_id ~r/\A[a-f0-9]{32}\z/

  @doc """
  The temporary passwords a request saved: those named by an approval outcome
  Phoenix recorded for it as approved and succeeded. The onboarding workflow
  keeps its account step in `approval_history`, so the new account's password
  stays offered after the ticket step, whatever that step's outcome. Today a
  request saves at most one.
  """
  @spec offered_credentials(map()) :: [String.t()]
  def offered_credentials(%{result: %{} = result}) do
    history = Enum.map(List.wrap(result["approval_history"]), &(is_map(&1) and &1["execution"]))

    [result["approval_execution"] | history]
    |> Enum.flat_map(&succeeded_credential/1)
    |> Enum.uniq()
  end

  def offered_credentials(_job), do: []

  defp succeeded_credential(%{
         "execution_status" => "succeeded",
         "approval_status" => "approved",
         "result" => %{"credential_id" => credential_id}
       })
       when is_binary(credential_id) do
    if Regex.match?(@credential_id, credential_id), do: [credential_id], else: []
  end

  defp succeeded_credential(_outcome), do: []

  @type subject :: %{required(String.t()) => String.t()}

  @spec reveal(map(), String.t(), String.t()) ::
          {:ok, %{subject: subject(), temporary_password: String.t()}}
          | {:error,
             :forbidden
             | :credential_not_found
             | :credential_already_revealed
             | :credential_expired
             | :credential_unreadable
             | term()}
  def reveal(user, job_id, credential_id)
      when is_map(user) and is_binary(job_id) and is_binary(credential_id) do
    with {:ok, job} <- Jobs.get(job_id),
         true <- Authorization.owns_resource?(user, job.user_id) || {:error, :forbidden},
         :ok <- named_by_approved_outcome(job, credential_id),
         {:ok, credential} <- fetch(credential_id),
         :ok <- usable(credential),
         {:ok, vault} <- vault(),
         {:ok, aad, subject} <- binding(credential, vault),
         {:ok, password} <- decrypt(credential, vault, aad),
         :ok <- consume(credential_id, user["user_id"]) do
      {:ok, %{subject: subject, temporary_password: password}}
    end
  end

  # Only a credential the request's own recorded, succeeded approval names.
  defp named_by_approved_outcome(job, credential_id) do
    if credential_id in offered_credentials(job),
      do: :ok,
      else: {:error, :credential_not_found}
  end

  defp fetch(credential_id) do
    statement = "SELECT * FROM ONLY type::record('credential_secret', $id);"

    case Surreal.query(statement, %{"id" => credential_id}) do
      {:ok, [%{"status" => "OK", "result" => credential}]} when is_map(credential) ->
        {:ok, credential}

      {:ok, [%{"status" => "OK"}]} ->
        {:error, :credential_not_found}

      {:ok, other} ->
        {:error, {:unexpected_surreal_result, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp usable(%{"kind" => "temporary_password"} = credential) do
    cond do
      credential["consumed_at"] != nil -> {:error, :credential_already_revealed}
      expired?(credential["expires_at"]) -> {:error, :credential_expired}
      true -> :ok
    end
  end

  defp usable(_credential), do: {:error, :credential_not_found}

  defp expired?(expires_at) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, moment, _offset} -> DateTime.compare(moment, DateTime.utc_now()) != :gt
      _ -> true
    end
  end

  defp expired?(_), do: true

  defp vault do
    {:ok, RuntimeConfig.credential_vault!()}
  rescue
    error in RuntimeConfig.Error -> {:error, {:credential_vault_configuration, error.message}}
  end

  # The authenticated data each sealing path wrote, rebuilt from stored fields.
  defp binding(%{"subject_type" => "mailbox"} = credential, vault) do
    fields = [credential["mailbox_record_id"], credential["provider"], credential["email"]]

    with :ok <- present(fields) do
      {:ok, aad([credential["credential_id"], "mailbox" | fields], vault),
       %{"kind" => "mailbox", "email" => credential["email"]}}
    end
  end

  defp binding(
         %{"subject_type" => "directory_account", "issued_by" => "password_reset"} = credential,
         vault
       ) do
    user_id = credential["directory_user_id"]

    with :ok <- present([user_id]) do
      {:ok, aad([credential["credential_id"], "directory_account", user_id], vault),
       %{"kind" => "directory_account", "user_id" => user_id}}
    end
  end

  defp binding(%{"subject_type" => "directory_account"} = credential, vault) do
    user_id = credential["directory_user_id"]

    with :ok <- present([user_id, credential["email"]]) do
      {:ok, aad([credential["credential_id"], user_id, credential["email"]], vault),
       %{"kind" => "directory_account", "user_id" => user_id, "email" => credential["email"]}}
    end
  end

  defp binding(_credential, _vault), do: {:error, :credential_unreadable}

  defp aad(parts, vault), do: Enum.join([@aad_version | parts] ++ [vault.key_version], "|")

  defp present(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, :credential_unreadable}
  end

  # The tag authenticates the ciphertext against the authenticated data rebuilt
  # from the stored identity, so a ciphertext moved to another record fails here.
  defp decrypt(credential, vault, aad) do
    with true <- credential["key_version"] == vault.key_version,
         {:ok, iv} <- Base.decode64(credential["iv_b64"] || ""),
         {:ok, ciphertext} <- Base.decode64(credential["ciphertext_b64"] || ""),
         {:ok, tag} <- Base.decode64(credential["tag_b64"] || ""),
         password when is_binary(password) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, vault.key, iv, ciphertext, aad, tag, false) do
      {:ok, password}
    else
      _ -> {:error, :credential_unreadable}
    end
  rescue
    _ -> {:error, :credential_unreadable}
  end

  # Marks the credential used and erases the ciphertext in one step, only if no
  # other reveal got there first.
  defp consume(credential_id, user_id) do
    statement = """
    UPDATE type::record('credential_secret', $id)
    SET consumed_at = time::now(), consumed_by = $user_id,
        ciphertext_b64 = NONE, iv_b64 = NONE, tag_b64 = NONE
    WHERE consumed_at = NONE OR consumed_at = NULL
    RETURN AFTER;
    """

    case Surreal.query(statement, %{"id" => credential_id, "user_id" => user_id}) do
      {:ok, [%{"status" => "OK", "result" => [%{"consumed_by" => ^user_id}]}]} -> :ok
      {:ok, [%{"status" => "OK", "result" => []}]} -> {:error, :credential_already_revealed}
      {:ok, other} -> {:error, {:unexpected_surreal_result, other}}
      {:error, reason} -> {:error, reason}
    end
  end
end
