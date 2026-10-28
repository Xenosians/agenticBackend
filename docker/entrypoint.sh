#!/bin/sh
set -eu
case "${1:-}" in
  start)
    exec /app/bin/itsm_backend start
    ;;
  schema)
    # Explicit one-off DDL only. Do not start QueueWorker or the mail outbox.
    exec /app/bin/itsm_backend eval 'Application.ensure_all_started(:req) |> then(fn {:ok, _} -> :ok; {:error, _} -> raise "schema transport unavailable" end); case ItsmBackend.Storage.Schema.ensure() do :ok -> IO.puts("ITSM SURREAL SCHEMA: OK"); {:error, _} -> raise "schema initialization failed" end'
    ;;
  *)
    echo 'Supported commands: start, schema' >&2
    exit 64
    ;;
esac
