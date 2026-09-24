defmodule ItsmBackend.Storage.Schema do
  @moduledoc """
  Idempotent SurrealDB schema bootstrap for application identity,
  authenticated sessions, durable auth tokens, and user-owned chats.

  Runtime request paths do not call this module. Deployments run the
  corresponding Mix task before starting a backend version that depends
  on these tables. This keeps DDL authority separate from normal request
  processing while supporting STRICT SurrealDB databases.
  """

  alias ItsmBackend.Surreal

  @statements [
    "DEFINE TABLE IF NOT EXISTS app_user SCHEMALESS PERMISSIONS NONE;",
    "DEFINE TABLE IF NOT EXISTS auth_identity SCHEMALESS PERMISSIONS NONE;",
    "DEFINE TABLE IF NOT EXISTS auth_session SCHEMALESS PERMISSIONS NONE;",
    "DEFINE TABLE IF NOT EXISTS auth_token SCHEMALESS PERMISSIONS NONE;",
    "DEFINE TABLE IF NOT EXISTS chat SCHEMALESS PERMISSIONS NONE;",
    "DEFINE INDEX IF NOT EXISTS auth_identity_user_id ON TABLE auth_identity FIELDS user_id UNIQUE;",
    "DEFINE INDEX IF NOT EXISTS auth_session_token_hash ON TABLE auth_session FIELDS token_hash UNIQUE;",
    "DEFINE INDEX IF NOT EXISTS auth_session_user_id ON TABLE auth_session FIELDS user_id;",
    "DEFINE INDEX IF NOT EXISTS auth_token_user_purpose ON TABLE auth_token FIELDS user_id, purpose;",
    "DEFINE INDEX IF NOT EXISTS chat_user_id ON TABLE chat FIELDS user_id;"
  ]

  @spec ensure() :: :ok | {:error, term()}
  def ensure do
    Enum.reduce_while(
      @statements,
      :ok,
      fn statement, :ok ->
        case Surreal.query(statement) do
          {:ok, _results} ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt,
             {:error,
              {
                :schema_statement_failed,
                statement,
                reason
              }}}
        end
      end
    )
  end

  @spec statements() :: [String.t()]
  def statements do
    @statements
  end
end
