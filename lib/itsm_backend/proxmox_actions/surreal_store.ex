defmodule ItsmBackend.ProxmoxActions.SurrealStore do
  @moduledoc false

  alias ItsmBackend.Surreal

  @table "proxmox_action"
  # Fields compared when the same submission arrives again.
  @binding ~w(user_id submission_id action node vmid)

  @doc """
  Creates the action once. CREATE on the deterministic record id is the
  uniqueness boundary; a retry returns the saved action, and a different
  target under the same submission is a conflict.
  """
  def create_idempotent(action) do
    case create(action) do
      {:ok, stored} ->
        {:ok, stored, :created}

      {:error, create_error} ->
        case get(action["action_id"]) do
          {:ok, nil} ->
            {:error, create_error}

          {:ok, stored} ->
            if Map.take(stored, @binding) == Map.take(action, @binding),
              do: {:ok, stored, :existing},
              else: {:error, :proxmox_action_conflict}

          {:error, _read_error} ->
            {:error, {:proxmox_action_outcome_unknown, create_error}}
        end
    end
  end

  def get(action_id) do
    statement = "SELECT * FROM ONLY type::record($table, $id);"

    with {:ok, results} <- Surreal.query(statement, %{"table" => @table, "id" => action_id}),
         {:ok, record} <- single(results) do
      {:ok, record && public(record)}
    end
  end

  def list_for_user(user_id, limit) do
    statement = """
    SELECT * FROM proxmox_action
    WHERE user_id = $user_id
    ORDER BY created_at DESC
    LIMIT $limit;
    """

    with {:ok, results} <- Surreal.query(statement, %{"user_id" => user_id, "limit" => limit}),
         {:ok, rows} <- rows(results) do
      {:ok, Enum.map(rows || [], &public/1)}
    end
  end

  @doc """
  Moves the action from `from` to `to` (with `fields`) only while it is still
  in `from`; `{:error, :stale}` means another request moved it first.
  """
  def transition(action_id, from, to, fields) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    MERGE $fields
    WHERE status = $from
    RETURN AFTER;
    """

    params = %{
      "table" => @table,
      "id" => action_id,
      "from" => from,
      "fields" => fields |> Map.put("status", to) |> Surreal.datetime_fields(["decided_at"])
    }

    with {:ok, results} <- Surreal.query(statement, params),
         {:ok, record} <- single(results) do
      if is_map(record), do: {:ok, public(record)}, else: {:error, :stale}
    end
  end

  defp create(action) do
    statement = "CREATE ONLY type::record($table, $id) CONTENT $action RETURN AFTER;"

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @table,
             "id" => action["action_id"],
             "action" => Surreal.datetime_fields(action, ["created_at"])
           }),
         {:ok, record} <- single(results),
         true <- is_map(record) || {:error, :proxmox_action_not_created} do
      {:ok, public(record)}
    end
  end

  # The storage record id duplicates action_id; it is not part of the API.
  defp public(record), do: Map.delete(record, "id")

  defp single(results) do
    with {:ok, result} <- rows(results) do
      case result do
        nil -> {:ok, nil}
        [] -> {:ok, nil}
        [record | _] when is_map(record) -> {:ok, record}
        record when is_map(record) -> {:ok, record}
        other -> {:error, {:unexpected_proxmox_action_result, other}}
      end
    end
  end

  defp rows([%{"status" => "OK", "result" => result} | _]), do: {:ok, result}
  defp rows(other), do: {:error, {:unexpected_surreal_response, other}}
end
