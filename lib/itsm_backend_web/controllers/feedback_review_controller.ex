defmodule ItsmBackendWeb.FeedbackReviewController do
  @moduledoc """
  The reviewer queue for critiques and corrections (SRS 1.9 FR-089).
  Administrators read pending feedback and record one decision per record;
  a decision never changes the task, its approval, permissions or weights.
  """
  use ItsmBackendWeb, :controller

  use ItsmBackendWeb.RequestContract

  request_contract(:index, optional_query: ["status"])
  request_contract(:review, required_body: ["decision", "reason"])

  require Logger

  alias ItsmBackend.JobFeedback
  alias ItsmBackendWeb.AuthRequest
  alias ItsmBackendWeb.PublicError

  def index(conn, params) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} ->
        case JobFeedback.review_queue(ctx.user, params["status"]) do
          {:ok, feedback} ->
            json(conn, %{feedback: feedback})

          {:error, :forbidden} ->
            conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

          {:error, :invalid_review_filter} ->
            PublicError.render(
              conn,
              :unprocessable_entity,
              "invalid_review_filter",
              "Choose pending or all feedback."
            )

          {:error, reason} ->
            Logger.error("feedback review queue failed: #{inspect(reason)}")

            PublicError.render(
              conn,
              :internal_server_error,
              "feedback_lookup_failed",
              "Feedback for review could not be loaded.",
              retryable: true
            )
        end

      {:error, conn} ->
        conn
    end
  end

  def review(conn, %{"id" => feedback_id} = params) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} ->
        decide(conn, ctx.user, feedback_id, Map.take(params, ["decision", "reason"]))

      {:error, conn} ->
        conn
    end
  end

  defp decide(conn, reviewer, feedback_id, params) do
    case JobFeedback.review(reviewer, feedback_id, params) do
      {:ok, feedback} ->
        json(conn, %{feedback: feedback})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, :invalid_review} ->
        PublicError.render(
          conn,
          :unprocessable_entity,
          "invalid_review",
          "Choose accepted or dismissed and give a reason of up to 2000 characters."
        )

      {:error, :feedback_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "feedback_not_found"})

      {:error, :review_conflict} ->
        PublicError.render(
          conn,
          :conflict,
          "review_conflict",
          "This feedback already has a different decision."
        )

      {:error, reason} ->
        Logger.error("feedback review failed: #{inspect(reason)}")

        PublicError.render(
          conn,
          :service_unavailable,
          "review_outcome_unknown",
          "The decision could not be confirmed. Reload the queue before deciding again.",
          retryable: true
        )
    end
  end
end
