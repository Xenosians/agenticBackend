defmodule ItsmBackend.JobFeedback do
  @moduledoc """
  Critiques and corrections of a task's result, saved for review (SRS 1.9
  FR-089).

  Each record links the owner's note to the original request, chat, task,
  proposal and provenance. The subject is copied when the note is saved, so
  a later decision or retry of the task cannot change what was reviewed.

  Feedback is review evidence only. It never changes the task, its approval,
  tool permissions, live policy or serving weights; a reviewer decides what,
  if anything, it becomes.
  """

  alias ItsmBackend.Auth.Authorization
  alias ItsmBackend.JobFeedback.SurrealStore
  alias ItsmBackend.Jobs

  @note_max 2000
  @list_limit 200
  # Feedback describes a result the user has seen: an answer, a proposal
  # awaiting a decision, or a final outcome.
  @reviewable_statuses ~w(waiting_approval completed failed denied outcome_unknown reconciliation_required)
  @submission_identity ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @feedback_identity ~r/\A[0-9a-f]{32}\z/
  # A reviewer's decision. Accepted feedback is evidence a reviewer may later
  # curate into evaluation or training data; nothing is applied automatically.
  @decisions ~w(accepted dismissed)
  @review_filters %{"pending" => "pending_review", "all" => nil}

  @doc """
  Saves the owner's feedback on a task once per submission identity.

  Returns `{:ok, feedback, :created}` for a new record and
  `{:ok, feedback, :existing}` when the same submission was already saved.
  """
  def submit(user, job_id, params) when is_map(params) do
    with {:ok, input} <- validate(params),
         {:ok, job} <- Jobs.get(job_id),
         true <- Authorization.owns_resource?(user, job.user_id) || {:error, :forbidden},
         true <- job.status in @reviewable_statuses || {:error, :job_not_ready_for_feedback} do
      job
      |> build(input)
      |> SurrealStore.create_idempotent()
    end
  end

  def submit(_user, _job_id, _params), do: {:error, :invalid_feedback}

  @doc "The user's feedback, newest first."
  def list(user), do: SurrealStore.list_for_user(user["user_id"], @list_limit)

  @doc """
  The reviewer queue: pending feedback (or every record with `"all"`),
  oldest first so the longest-waiting feedback is reviewed first.
  """
  def review_queue(reviewer, filter) do
    with :ok <- require_reviewer(reviewer),
         {:ok, status} <- review_filter(filter) do
      SurrealStore.list_for_review(status, @list_limit)
    end
  end

  @doc """
  Records a reviewer's decision once. Repeating the same decision returns it;
  a different decision is a conflict. The task is never changed.
  """
  def review(reviewer, feedback_id, params) when is_map(params) do
    with :ok <- require_reviewer(reviewer),
         true <- valid_feedback_id?(feedback_id) || {:error, :feedback_not_found},
         {:ok, decision} <- decision(params["decision"]),
         {:ok, reason} <- review_reason(params["reason"]) do
      SurrealStore.record_review(feedback_id, %{
        "decision" => decision,
        "reason" => reason,
        "reviewer_id" => reviewer["user_id"],
        "reviewed_at" =>
          DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
      })
    end
  end

  def review(_reviewer, _feedback_id, _params), do: {:error, :invalid_review}

  defp require_reviewer(%{"role" => "admin"}), do: :ok
  defp require_reviewer(_user), do: {:error, :forbidden}

  defp review_filter(nil), do: {:ok, @review_filters["pending"]}

  defp review_filter(value) when is_map_key(@review_filters, value),
    do: {:ok, @review_filters[value]}

  defp review_filter(_value), do: {:error, :invalid_review_filter}

  defp valid_feedback_id?(value), do: is_binary(value) and Regex.match?(@feedback_identity, value)

  defp decision(value) when value in @decisions, do: {:ok, value}
  defp decision(_value), do: {:error, :invalid_review}

  defp review_reason(value) do
    case text(value, required: true) do
      {:ok, reason} -> {:ok, reason}
      _ -> {:error, :invalid_review}
    end
  end

  defp validate(params) do
    with {:ok, submission_id} <- submission_id(params["submission_id"]),
         {:ok, note} <- text(params["note"], required: true),
         {:ok, correction} <- text(params["correction"], required: false) do
      {:ok, %{submission_id: submission_id, note: note, correction: correction}}
    end
  end

  defp submission_id(value) when is_binary(value) do
    if Regex.match?(@submission_identity, value),
      do: {:ok, value},
      else: {:error, :invalid_feedback}
  end

  defp submission_id(_value), do: {:error, :invalid_feedback}

  defp text(nil, required: false), do: {:ok, nil}
  defp text(nil, required: true), do: {:error, :invalid_feedback}

  defp text(value, required: required) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" and required -> {:error, :invalid_feedback}
      value == "" -> {:ok, nil}
      String.length(value) > @note_max -> {:error, :invalid_feedback}
      true -> {:ok, value}
    end
  end

  defp text(_value, _opts), do: {:error, :invalid_feedback}

  defp build(job, input) do
    result = if is_map(job.result), do: job.result, else: %{}

    %{
      # One record per owner and submission; a retried submission finds it.
      "feedback_id" => feedback_id(job.user_id, input.submission_id),
      "submission_id" => input.submission_id,
      "user_id" => job.user_id,
      "chat_id" => job.conversation_id,
      "job_id" => job.id,
      "kind" => if(input.correction, do: "correction", else: "critique"),
      "note" => input.note,
      "correction" => input.correction,
      "subject" => %{
        "request" => job.message,
        "status" => job.status,
        "attempt" => job.attempts,
        "selected_agent" => job.selected_agent,
        "routes" => result["routes"],
        "proposed_tool" => job.proposed_tool,
        "answer" => result["answer"] || job.error,
        "workflow_contract_hash" => job.workflow_contract_hash
      },
      "review_status" => "pending_review",
      "created_at" =>
        DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    }
  end

  defp feedback_id(owner, submission_id) do
    :crypto.hash(:sha256, Jason.encode!(["job-feedback-v1", owner, submission_id]))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end
end
