defmodule ItsmBackend.ProvisionedMailboxes.SurrealStore do
  @moduledoc "Atomic mailbox metadata and encrypted credential persistence."

  alias ItsmBackend.Surreal

  @spec create(map(), map()) :: :ok | {:error, term()}
  def create(mailbox, credential) when is_map(mailbox) and is_map(credential) do
    with {:ok, false} <- mailbox_exists?(mailbox) do
      create_records(mailbox, credential)
    else
      {:ok, true} -> {:error, :mailbox_already_persisted}
      {:error, _} -> {:error, :mailbox_persistence_failed}
    end
  end

  defp create_records(mailbox, credential) do
    statement = """
    BEGIN TRANSACTION;
    CREATE ONLY type::record('provisioned_mailbox', $mailbox_id) CONTENT $mailbox;
    CREATE ONLY type::record('credential_secret', $credential_id) CONTENT $credential;
    COMMIT TRANSACTION;
    """

    params = %{
      "mailbox_id" => Map.fetch!(mailbox, "mailbox_record_id"),
      "mailbox" => mailbox,
      "credential_id" => Map.fetch!(credential, "credential_id"),
      "credential" => credential
    }

    case Surreal.query(statement, params) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        # The unique index closes the race after the preflight read. SurrealDB
        # may report the transaction cancellation before the underlying index
        # error, so identify a concurrent duplicate using metadata, not error text.
        case mailbox_exists?(mailbox) do
          {:ok, true} -> {:error, :mailbox_already_persisted}
          _ -> {:error, :mailbox_persistence_failed}
        end
    end
  end

  defp mailbox_exists?(mailbox) do
    statement = """
    SELECT VALUE mailbox_record_id FROM provisioned_mailbox
      WHERE provider = $provider AND email = $email LIMIT 1;
    """

    params = Map.take(mailbox, ["provider", "email"])

    case Surreal.query(statement, params) do
      {:ok, [%{"result" => result}]} when is_list(result) -> {:ok, result != []}
      _ -> {:error, :mailbox_persistence_failed}
    end
  end
end
