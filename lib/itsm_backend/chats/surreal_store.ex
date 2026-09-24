defmodule ItsmBackend.Chats.SurrealStore do
  @moduledoc false

  alias ItsmBackend.Surreal

  @table "chat"

  def create(chat) do
    statement = "CREATE ONLY type::record($table, $id) CONTENT $chat RETURN AFTER;"

    with {:ok, results} <-
           Surreal.query(statement, %{"table" => @table, "id" => chat["chat_id"], "chat" => chat}),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  def get(chat_id) do
    statement = "SELECT * FROM ONLY type::record($table, $id);"

    with {:ok, results} <- Surreal.query(statement, %{"table" => @table, "id" => chat_id}),
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

  def touch(chat_id, now) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET updated_at = $now
    RETURN AFTER;
    """

    with {:ok, results} <- Surreal.query(statement, %{"table" => @table, "id" => chat_id, "now" => now}),
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
end
