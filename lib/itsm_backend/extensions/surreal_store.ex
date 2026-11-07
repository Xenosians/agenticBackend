defmodule ItsmBackend.Extensions.SurrealStore do
  @moduledoc false

  alias ItsmBackend.Surreal

  @table "extension_record"
  @event_table "extension_event"

  # Target states that also stamp a lifecycle timestamp on the record.
  @transition_timestamps %{
    "reviewed" => "reviewed_at",
    "active" => "activated_at",
    "revoked" => "revoked_at"
  }

  def create(record, event) do
    statement = """
    BEGIN TRANSACTION;
    CREATE ONLY type::record($table, $id) CONTENT $record;
    CREATE ONLY type::record($event_table, $event_id) CONTENT $event;
    COMMIT TRANSACTION;
    """

    params = %{
      "table" => @table,
      "id" => record["record_id"],
      "record" => Surreal.datetime_fields(record, ~w(created_at updated_at)),
      "event_table" => @event_table,
      "event_id" => event["event_id"],
      "event" => Surreal.datetime_fields(event, ~w(created_at))
    }

    case Surreal.query(statement, params) do
      {:ok, _} ->
        verify_created(record)

      {:error, _} ->
        # A lost race or transport fault is decided by reading this exact
        # identity back, never by re-creating it with different content.
        case get(record["record_id"]) do
          {:ok, stored} when is_map(stored) ->
            if stored["user_id"] == record["user_id"] and
                 stored["manifest_sha256"] == record["manifest_sha256"] and
                 stored["source_sha256"] == record["source_sha256"] do
              verify_register_event(stored)
            else
              {:error, :identity_conflict}
            end

          {:ok, nil} ->
            {:error, :record_outcome_unknown}

          error ->
            error
        end
    end
  end

  def get(record_id) do
    statement = "SELECT * FROM ONLY type::record($table, $id);"

    with {:ok, results} <- Surreal.query(statement, %{"table" => @table, "id" => record_id}),
         {:ok, record} <- single(results) do
      {:ok, record && normalize(record)}
    end
  end

  def list_for_user(user_id, limit) do
    statement = """
    SELECT * FROM extension_record
    WHERE user_id = $user_id
    ORDER BY updated_at DESC
    LIMIT $limit;
    """

    with {:ok, results} <- Surreal.query(statement, %{"user_id" => user_id, "limit" => limit}),
         {:ok, rows} <- rows(results) do
      {:ok, Enum.map(rows || [], &normalize/1)}
    end
  end

  @doc """
  Applies one guarded lifecycle transition together with its audit event in a
  single transaction. Zero matching rows abort the transaction, so a replayed
  transition neither duplicates an event nor rewrites history.
  """
  def transition(user_id, record_id, sources, action, target, event) do
    timestamp_set = transition_set(target)

    statement = """
    BEGIN TRANSACTION;
    LET $updated = (
      UPDATE ONLY type::record($table, $id)
      SET status = $target, updated_at = $now#{timestamp_set}
      WHERE user_id = $owner AND status IN $sources
      RETURN AFTER
    );
    IF $updated == NONE { THROW 'extension_transition_not_allowed'; };
    CREATE ONLY type::record($event_table, $event_id) CONTENT $event;
    COMMIT TRANSACTION;
    """

    params = %{
      "table" => @table,
      "id" => record_id,
      "target" => target,
      "now" => Surreal.datetime(event["created_at"]),
      "owner" => user_id,
      "sources" => sources,
      "event_table" => @event_table,
      "event_id" => event["event_id"],
      "event" => Surreal.datetime_fields(event, ~w(created_at))
    }

    _ = Surreal.query(statement, params)

    with {:ok, record} when is_map(record) <- get(record_id),
         true <- record["user_id"] == user_id || {:error, :not_found} do
      cond do
        record["status"] == target and
            transition_event_present?(user_id, record_id, action, target) ->
          {:ok, record}

        record["status"] == target ->
          {:error, :transition_outcome_unknown}

        record["status"] in sources ->
          # The guard rejected nothing, so the transaction failed elsewhere.
          {:error, :transition_outcome_unknown}

        true ->
          {:error, {:transition_not_allowed, record["status"]}}
      end
    else
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  def list_events(user_id, record_id, limit) do
    statement = """
    SELECT * FROM extension_event
    WHERE user_id = $user_id AND record_id = $record_id
    ORDER BY created_at ASC
    LIMIT $limit;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "user_id" => user_id,
             "record_id" => record_id,
             "limit" => limit
           }),
         {:ok, rows} <- rows(results) do
      {:ok, Enum.map(rows || [], &normalize_event/1)}
    end
  end

  defp transition_event_present?(user_id, record_id, action, target) do
    with {:ok, events} <- list_events(user_id, record_id, 500) do
      Enum.any?(events, &(&1["action"] == action and &1["to_status"] == target))
    else
      _ -> false
    end
  end

  defp verify_created(record) do
    with {:ok, stored} when is_map(stored) <- get(record["record_id"]),
         true <-
           matches_fields?(
             stored,
             Map.take(
               record,
               ~w(record_id user_id kind extension_id record_version status source_type source_sha256 manifest_sha256)
             )
           ) do
      {:ok, stored}
    else
      _ -> {:error, :record_outcome_unknown}
    end
  end

  defp verify_register_event(stored) do
    with {:ok, events} <- list_events(stored["user_id"], stored["record_id"], 500),
         true <-
           Enum.any?(events, &(&1["action"] == "register")) ||
             {:error, :record_outcome_unknown} do
      {:ok, stored}
    else
      error -> error
    end
  end

  defp transition_set(target) do
    case Map.fetch(@transition_timestamps, target) do
      {:ok, field} -> ", #{field} = $now"
      :error -> ""
    end
  end

  defp normalize(record) do
    record
    |> Map.delete("id")
    |> Map.update("created_at", nil, &encode_time/1)
    |> Map.update("updated_at", nil, &encode_time/1)
    |> Map.update("reviewed_at", nil, &encode_time/1)
    |> Map.update("activated_at", nil, &encode_time/1)
    |> Map.update("revoked_at", nil, &encode_time/1)
  end

  defp normalize_event(event) do
    event
    |> Map.delete("id")
    |> Map.update("created_at", nil, &encode_time/1)
  end

  defp matches_fields?(record, expected),
    do: is_map(record) and Enum.all?(expected, fn {field, value} -> record[field] === value end)

  defp encode_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_time(value), do: value

  defp single(results) do
    with {:ok, result} <- rows(results) do
      case result do
        nil -> {:ok, nil}
        [] -> {:ok, nil}
        [record] when is_map(record) -> {:ok, record}
        record when is_map(record) -> {:ok, record}
        other -> {:error, {:unexpected_extension_result, other}}
      end
    end
  end

  defp rows([%{"status" => "OK", "result" => result} | _]), do: {:ok, result}
  defp rows(other), do: {:error, {:unexpected_surreal_response, other}}
end
