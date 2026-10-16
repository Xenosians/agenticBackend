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

  @spec ensure() :: :ok | {:error, term()}
  def ensure do
    with {:ok, schema} <- File.read(schema_path()),
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

  # Bootstrap and isolated tests apply the same canonical schema. Keeping a
  # second DDL list here previously omitted new credential tables and indexes.
  defp schema_path do
    :itsm_backend |> :code.priv_dir() |> to_string() |> Path.join("surreal/schema.surql")
  end
end
