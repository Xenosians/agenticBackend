defmodule ItsmBackend.ProvisionedAccounts.SurrealStore do
  @moduledoc """
  Atomic SurrealDB persistence for provisioned account metadata and
  encrypted temporary credentials.
  """

  alias ItsmBackend.Surreal

  @account_table "provisioned_account"
  @credential_table "credential_secret"

  @spec create(map(), map()) :: :ok | {:error, term()}
  def create(account_record, credential_record)
      when is_map(account_record) and is_map(credential_record) do
    statement = """
    BEGIN TRANSACTION;
    CREATE ONLY type::record($account_table, $account_id)
      CONTENT $account_record;
    CREATE ONLY type::record($credential_table, $credential_id)
      CONTENT $credential_record;
    COMMIT TRANSACTION;
    """

    params = %{
      "account_table" => @account_table,
      "account_id" => Map.fetch!(account_record, "account_record_id"),
      "account_record" => account_record,
      "credential_table" => @credential_table,
      "credential_id" => Map.fetch!(credential_record, "credential_id"),
      "credential_record" => credential_record
    }

    case Surreal.query(statement, params) do
      {:ok, _results} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
