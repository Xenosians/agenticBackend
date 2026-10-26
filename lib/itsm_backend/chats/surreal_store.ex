defmodule ItsmBackend.Chats.SurrealStore do
  @moduledoc false

  alias ItsmBackend.Surreal

  @table "chat"

  def create(chat) do
    statement = "CREATE ONLY type::record($table, $id) CONTENT $chat RETURN AFTER;"

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @table,
             "id" => chat["chat_id"],
             "chat" => Surreal.datetime_fields(chat, ~w(created_at updated_at archived_at))
           }),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  def get(chat_id) do
    statement = "SELECT * FROM ONLY type::record($table, $id);"

    with {:ok, chat_id} <- canonical_id(chat_id),
         {:ok, results} <- Surreal.query(statement, %{"table" => @table, "id" => chat_id}),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  def list_for_user(user_id) do
    statement = """
    SELECT * FROM chat
    WHERE user_id = $user_id AND archived_at = $archived_at
    ORDER BY updated_at DESC;
    """

    with {:ok, results} <- Surreal.query(statement, %{"user_id" => user_id, "archived_at" => nil}),
         {:ok, rows} <- rows(results) do
      {:ok, rows || []}
    end
  end

  @doc """
  One owner's saved turns whose request text contains `needle`. The needle is
  a bound parameter compared case-insensitively as literal text.
  """
  def matching_turns(user_id, needle, limit) do
    statement = """
    SELECT conversation_id, message, created_at FROM job
    WHERE user_id = $user_id
      AND type::is_string(conversation_id)
      AND string::contains(string::lowercase(message), $needle)
    ORDER BY created_at DESC
    LIMIT $limit;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{"user_id" => user_id, "needle" => needle, "limit" => limit}),
         {:ok, rows} <- rows(results) do
      {:ok, rows || []}
    end
  end

  def touch(chat_id, now) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET updated_at = $now
    RETURN AFTER;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @table,
             "id" => chat_id,
             "now" => Surreal.datetime(now)
           }),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  def archive(chat_id, now) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET archived_at = $now,
        updated_at = $now
    RETURN AFTER;
    """

    with {:ok, results} <-
           Surreal.query(
             statement,
             %{
               "table" => @table,
               "id" => chat_id,
               "now" => Surreal.datetime(now)
             }
           ),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  defp single_or_nil(results) do
    with {:ok, result} <- rows(results) do
      case result do
        nil -> {:ok, nil}
        [] -> {:ok, nil}
        [record | _] when is_map(record) -> {:ok, record}
        record when is_map(record) -> {:ok, record}
        other -> {:error, {:unexpected_chat_result, other}}
      end
    end
  end

  defp rows([%{"status" => "OK", "result" => result} | _]), do: {:ok, result}
  defp rows(other), do: {:error, {:unexpected_surreal_response, other}}

  # The public API already accepts the storage-record alias. Resolve this one
  # documented identity shape explicitly instead of relying on RPC coercion.
  # Generated chat identities are 16 random bytes encoded as lowercase hex.
  defp canonical_id(@table <> ":" <> alias_id) do
    case Regex.run(~r/\A(?:([0-9a-f]{32})|⟨([0-9a-f]{32})⟩|`([0-9a-f]{32})`)\z/u, alias_id) do
      [_ | captures] -> {:ok, Enum.find(captures, &(&1 != ""))}
      _ -> {:error, :not_found}
    end
  end

  defp canonical_id(id) when is_binary(id), do: {:ok, id}
  defp canonical_id(_), do: {:error, :not_found}
end
