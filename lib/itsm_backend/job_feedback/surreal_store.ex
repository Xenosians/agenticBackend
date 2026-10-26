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

  @doc "Feedback for review, oldest first; `nil` status lists every record."
  def list_for_review(review_status, limit) do
    filter = if review_status, do: "WHERE review_status = $review_status", else: ""

    statement = """
    SELECT * FROM job_feedback #{filter}
    ORDER BY created_at ASC
    LIMIT $limit;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{"review_status" => review_status, "limit" => limit}),
         {:ok, rows} <- rows(results) do
      {:ok, Enum.map(rows || [], &public/1)}
    end
  end

  @doc """
  Records a decision once: the UPDATE only applies while the record is still
  pending, so concurrent reviewers cannot overwrite each other. A repeat of
  the stored decision returns it; any other decision is a conflict.
  """
  def record_review(feedback_id, review) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET review_status = $decision, review = $review
    WHERE review_status = "pending_review"
    RETURN AFTER;
    """

    params = %{
      "table" => @table,
      "id" => feedback_id,
      "decision" => review["decision"],
      "review" => Surreal.datetime_fields(review, ["reviewed_at"])
    }

    case Surreal.query(statement, params) do
      {:ok, results} ->
        case single(results) do
          {:ok, record} when is_map(record) -> {:ok, public(record)}
          {:ok, nil} -> existing_review(feedback_id, review)
          {:error, reason} -> {:error, {:review_outcome_unknown, reason}}
        end

      {:error, reason} ->
        # The write may or may not have applied; read back before answering.
        case existing_review(feedback_id, review) do
          {:ok, record} -> {:ok, record}
          {:error, :review_conflict} -> {:error, :review_conflict}
          {:error, :feedback_not_found} -> {:error, :feedback_not_found}
          _ -> {:error, {:review_outcome_unknown, reason}}
        end
    end
  end

  defp existing_review(feedback_id, review) do
    case get(feedback_id) do
      {:ok, nil} ->
        {:error, :feedback_not_found}

      {:ok, %{"review" => %{} = stored} = record} ->
        if Map.take(stored, ["decision", "reason", "reviewer_id"]) ==
             Map.take(review, ["decision", "reason", "reviewer_id"]),
           do: {:ok, record},
           else: {:error, :review_conflict}

      {:ok, _still_pending} ->
        {:error, :review_outcome_unknown}

      {:error, reason} ->
        {:error, {:review_outcome_unknown, reason}}
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
