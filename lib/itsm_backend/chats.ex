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

  def history(user, chat_id, limit \\ 100) do
    with {:ok, chat} <- get_authorized(user, chat_id),
         {:ok, jobs} <- Jobs.list_by_conversation(chat["user_id"], chat_id, limit) do
      {:ok, Enum.flat_map(jobs, &job_turns/1)}
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

  defp job_turns(job) do
    user_turn = %{
      "role" => "user",
      "content" => job.message,
      "job_id" => job.id,
      "created_at" => encode_time(job.created_at),
      "status" => job.status
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
            "status" => job.status,
            "proposed_tool" => job.proposed_tool
          }
        ]
    end
  end

  defp assistant_content(%{status: "failed", error: error}) when is_binary(error), do: error

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
