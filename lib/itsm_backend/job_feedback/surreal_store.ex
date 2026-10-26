defmodule ItsmBackend.JobFeedback.SurrealStore do
  @moduledoc false

  alias ItsmBackend.Surreal

  @table "job_feedback"
  # Fields compared when the same submission arrives again.
  @binding ~w(user_id job_id note correction)

  @doc """
  Creates the record once. CREATE on the deterministic record id is the
  uniqueness boundary; a retry returns the saved record, and a different
  note under the same submission is a conflict.
  """
  def create_idempotent(feedback) do
    case create(feedback) do
      {:ok, stored} ->
        {:ok, stored, :created}

      {:error, create_error} ->
        case get(feedback["feedback_id"]) do
          {:ok, nil} ->
            {:error, create_error}

          {:ok, stored} ->
            if Map.take(stored, @binding) == Map.take(feedback, @binding),
              do: {:ok, stored, :existing},
              else: {:error, :feedback_conflict}

          {:error, _read_error} ->
            {:error, {:feedback_outcome_unknown, create_error}}
        end
    end
  end

  def list_for_user(user_id, limit) do
    statement = """
    SELECT * FROM job_feedback
    WHERE user_id = $user_id
    ORDER BY created_at DESC
    LIMIT $limit;
    """

    with {:ok, results} <- Surreal.query(statement, %{"user_id" => user_id, "limit" => limit}),
         {:ok, rows} <- rows(results) do
      {:ok, Enum.map(rows || [], &public/1)}
    end
  end

  defp create(feedback) do
    statement = "CREATE ONLY type::record($table, $id) CONTENT $feedback RETURN AFTER;"

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @table,
             "id" => feedback["feedback_id"],
             "feedback" => Surreal.datetime_fields(feedback, ["created_at"])
           }),
         {:ok, record} <- single(results),
         true <- is_map(record) || {:error, :feedback_not_created} do
      {:ok, public(record)}
    end
  end

  defp get(feedback_id) do
    statement = "SELECT * FROM ONLY type::record($table, $id);"

    with {:ok, results} <- Surreal.query(statement, %{"table" => @table, "id" => feedback_id}),
         {:ok, record} <- single(results) do
      {:ok, record && public(record)}
    end
  end

  # The storage record id duplicates feedback_id; it is not part of the API.
  defp public(record), do: Map.delete(record, "id")

  defp single(results) do
    with {:ok, result} <- rows(results) do
      case result do
        nil -> {:ok, nil}
        [] -> {:ok, nil}
        [record | _] when is_map(record) -> {:ok, record}
        record when is_map(record) -> {:ok, record}
        other -> {:error, {:unexpected_feedback_result, other}}
      end
    end
  end

  defp rows([%{"status" => "OK", "result" => result} | _]), do: {:ok, result}
  defp rows(other), do: {:error, {:unexpected_surreal_response, other}}
end
