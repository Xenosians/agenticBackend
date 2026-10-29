#!/bin/sh
set -eu
case "${1:-}" in
  start)
    exec /app/bin/itsm_backend start
    ;;
  schema)
    # Explicit one-off DDL only. Do not start QueueWorker or the mail outbox.
    # A failure prints its reason atoms only: never the reply text, which can
    # echo statements or connection details.
    exec /app/bin/itsm_backend eval 'Application.ensure_all_started(:req) |> then(fn {:ok, _} -> :ok; {:error, _} -> raise "schema transport unavailable" end); atoms = fn atoms, value when is_atom(value) -> [value]; atoms, value when is_tuple(value) -> value |> Tuple.to_list() |> Enum.flat_map(&atoms.(atoms, &1)); _, _ -> [] end; case ItsmBackend.Storage.Schema.ensure() do :ok -> IO.puts("ITSM SURREAL SCHEMA: OK"); {:error, reason} -> raise "schema initialization failed: " <> Enum.map_join(atoms.(atoms, reason), ".", &Atom.to_string/1) end'
    ;;
  *)
    echo 'Supported commands: start, schema' >&2
    exit 64
    ;;
esac
