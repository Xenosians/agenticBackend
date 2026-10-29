defmodule ItsmBackend.Storage.Schema do
  @moduledoc """
  Idempotent SurrealDB schema bootstrap for application identity,
  authenticated sessions, durable auth tokens, and user-owned chats.

  Runtime request paths do not call this module. Deployments run the
  corresponding Mix task before starting a backend version that depends
  on these tables. This keeps DDL authority separate from normal request
  processing while supporting STRICT SurrealDB databases.

  SurrealDB does not create a namespace or database on first use, so
  bootstrap defines the configured ones first. Both are `IF NOT EXISTS`.
  """

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackend.Surreal

  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_-]*\z/

  @spec ensure() :: :ok | {:error, term()}
  def ensure do
    with {:ok, schema} <- File.read(schema_path()),
         {:ok, scope} <- scope_statement(),
         {:ok, _results} <- Surreal.query(scope),
         {:ok, _results} <- Surreal.query(schema) do
      :ok
    else
      {:error, reason} -> {:error, {:schema_initialization_failed, reason}}
    end
  end

  @spec statements() :: [String.t()]
  def statements do
    [File.read!(schema_path())]
  end

  # Names are interpolated as identifiers, so only simple names are accepted.
  defp scope_statement do
    %{namespace: namespace, database: database} = RuntimeConfig.surrealdb!()

    if Regex.match?(@identifier, namespace) and Regex.match?(@identifier, database) do
      {:ok,
       "DEFINE NAMESPACE IF NOT EXISTS `#{namespace}`; USE NS `#{namespace}`; " <>
         "DEFINE DATABASE IF NOT EXISTS `#{database}`;"}
    else
      {:error, :invalid_storage_scope}
    end
  end

  # Bootstrap and isolated tests apply the same canonical schema. Keeping a
  # second DDL list here previously omitted new credential tables and indexes.
  defp schema_path do
    :itsm_backend |> :code.priv_dir() |> to_string() |> Path.join("surreal/schema.surql")
  end
end
