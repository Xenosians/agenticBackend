defmodule Mix.Tasks.Itsm.Schema.Ensure do
  use Mix.Task

  @shortdoc "Ensures required SurrealDB application tables and indexes exist"
  @requirements ["app.config"]

  @moduledoc """
  Defines the SurrealDB tables and indexes required by the authenticated
  backend application layer.

      mix itsm.schema.ensure

  The operation is idempotent and uses `IF NOT EXISTS`. It is intended as
  a deployment/bootstrap step before starting a backend version that uses
  application users, sessions, auth tokens, or chats.

  The full Phoenix application is intentionally not started by this task.
  Only Req and its transport dependencies are started so schema migration
  cannot dispatch AI jobs or expose the HTTP endpoint as a side effect.
  """

  @impl Mix.Task
  def run(_args) do
    case Application.ensure_all_started(:req) do
      {:ok, _started} ->
        ensure_schema!()

      {:error, reason} ->
        Mix.raise("failed to start Req for SurrealDB schema bootstrap: #{inspect(reason)}")
    end
  end

  defp ensure_schema! do
    case ItsmBackend.Storage.Schema.ensure() do
      :ok ->
        Mix.shell().info("ITSM SURREAL SCHEMA: OK")

      {:error, reason} ->
        Mix.raise("failed to ensure SurrealDB schema: #{inspect(reason)}")
    end
  end
end
