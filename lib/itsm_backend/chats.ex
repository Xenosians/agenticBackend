defmodule ItsmBackend.Chats do
  @moduledoc """
  Durable authenticated chat threads. Job rows remain the canonical turn
  records, so chat history and execution history cannot diverge.
  """

  alias ItsmBackend.Auth.Authorization
  alias ItsmBackend.Chats.SurrealStore
  alias ItsmBackend.Jobs

  def create(user, attrs \\ %{}) do
    now = now()
    title = normalize_title(Map.get(attrs, "title", Map.get(attrs, :title)))

    chat = %{
      "chat_id" => random_id(),
      "user_id" => user["user_id"],
      "title" => title,
      "created_at" => now,
      "updated_at" => now,
      "archived_at" => nil
    }

    SurrealStore.create(chat)
  end

  def list(user), do: SurrealStore.list_for_user(user["user_id"])

  @search_query_max 200
  @search_result_limit 50
  # Saved turns read per search; the newest matches win when there are more.
  @search_turn_limit 500

  @doc """
  The owner's active chats whose title or saved request text contains
  `query`, matched case-insensitively as literal text. Newest chats first;
  each result names what matched and, for a message, the matching turn.
  """
  def search(user, query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" ->
        {:error, :search_query_required}

      String.length(query) > @search_query_max ->
        {:error, :search_query_too_long}

      true ->
        needle = String.downcase(query)

        with {:ok, chats} <- list(user),
             {:ok, turns} <-
               SurrealStore.matching_turns(user["user_id"], needle, @search_turn_limit) do
          # Turns arrive newest first, so the first one kept per chat is its latest match.
          latest_turn =
            Enum.reduce(turns, %{}, fn turn, acc ->
              Map.put_new(acc, turn["conversation_id"], turn["message"])
            end)

          results =
            chats
            |> Enum.flat_map(&search_result(&1, needle, latest_turn))
            |> Enum.take(@search_result_limit)

          {:ok, results}
        end
    end
  end

  def search(_user, _query), do: {:error, :search_query_required}

  defp search_result(chat, needle, latest_turn) do
    title = chat["title"] || ""
    base = Map.take(chat, ["chat_id", "title", "updated_at"])

    cond do
      String.contains?(String.downcase(title), needle) ->
        [Map.merge(base, %{"matched" => "title", "excerpt" => nil})]

      Map.has_key?(latest_turn, chat["chat_id"]) ->
        [Map.merge(base, %{"matched" => "message", "excerpt" => latest_turn[chat["chat_id"]]})]

      true ->
        []
    end
  end

  def get_authorized(user, chat_id) do
    with {:ok, chat} <- SurrealStore.get(chat_id),
         true <- is_map(chat) || {:error, :not_found},
         true <- Authorization.owns_resource?(user, chat["user_id"]) || {:error, :forbidden} do
      {:ok, chat}
    else
      {:error, _} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def touch(chat_id), do: SurrealStore.touch(chat_id, now())

  def archive(user, chat_id) do
    with {:ok, chat} <- get_authorized(user, chat_id),
         {:ok, archived} <- SurrealStore.archive(chat["chat_id"], now()),
         true <- is_map(archived) || {:error, :not_found} do
      {:ok, archived}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def history(user, chat_id, limit \\ 100, version \\ 1) do
    with {:ok, chat} <- get_authorized(user, chat_id),
         {:ok, jobs} <- Jobs.list_by_conversation(chat["user_id"], chat["chat_id"], limit) do
      {:ok, Enum.flat_map(jobs, &job_turns(&1, version))}
    end
  end

  def ai_context(user_id, chat_id, exclude_job_id, max_turns) do
    with {:ok, jobs} <- Jobs.list_by_conversation(user_id, chat_id, max_turns * 2 + 2) do
      turns =
        jobs
        |> Enum.reject(&(&1.id == exclude_job_id))
        |> Enum.flat_map(&job_turns/1)
        |> Enum.take(-max_turns)
        |> Enum.map(&Map.take(&1, ["role", "content"]))

      {:ok, turns}
    end
  end

  defp job_turns(job, version \\ 1) do
    user_turn = %{
      "role" => "user",
      "content" => job.message,
      "workflow_contract" => job.workflow_contract,
      "workflow_contract_hash" => job.workflow_contract_hash,
      "job_id" => job.id,
      "created_at" => encode_time(job.created_at),
      "status" => ItsmBackend.Jobs.Lifecycle.wire_status(job.status, version)
    }

    case assistant_content(job) do
      nil ->
        [user_turn]

      content ->
        [
          user_turn,
          %{
            "role" => "assistant",
            "content" => content,
            "job_id" => job.id,
            "created_at" => encode_time(job.completed_at || job.claimed_at || job.created_at),
            "status" => ItsmBackend.Jobs.Lifecycle.wire_status(job.status, version),
            "proposed_tool" => job.proposed_tool
          }
        ]
    end
  end

  defp assistant_content(%{status: status, error: error})
       when status in ["failed", "denied", "outcome_unknown", "reconciliation_required"] and
              is_binary(error),
       do: error

  defp assistant_content(%{result: result}) when is_map(result) do
    Map.get(result, "answer") || Map.get(result, :answer)
  end

  defp assistant_content(_), do: nil

  defp normalize_title(nil), do: "New chat"

  defp normalize_title(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: "New chat", else: String.slice(value, 0, 160)
  end

  defp normalize_title(_), do: "New chat"

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  defp encode_time(nil), do: nil
  defp encode_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_time(value), do: value
end
