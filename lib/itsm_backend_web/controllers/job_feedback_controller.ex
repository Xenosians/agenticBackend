defmodule ItsmBackendWeb.JobFeedbackController do
  use ItsmBackendWeb, :controller

  use ItsmBackendWeb.RequestContract

  request_contract(:create,
    required_body: ["submission_id", "note"],
    optional_body: ["correction"]
  )

  request_contract(:index, [])

  require Logger

  alias ItsmBackend.JobFeedback
  alias ItsmBackendWeb.AuthRequest
  alias ItsmBackendWeb.PublicError

  def create(conn, %{"id" => job_id} = params) do
    case AuthRequest.require_authenticated(conn, csrf: true) do
      {:ok, conn, ctx} -> create_authenticated(conn, ctx.user, job_id, params)
      {:error, conn} -> conn
    end
  end

  def index(conn, _params) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} ->
        case JobFeedback.list(ctx.user) do
          {:ok, feedback} ->
            json(conn, %{feedback: feedback})

          {:error, reason} ->
            Logger.error("feedback lookup failed: #{inspect(reason)}")

            PublicError.render(
              conn,
              :internal_server_error,
              "feedback_lookup_failed",
              "Saved feedback could not be loaded.",
              retryable: true
            )
        end

      {:error, conn} ->
        conn
    end
  end

  defp create_authenticated(conn, user, job_id, params) do
    case JobFeedback.submit(
           user,
           job_id,
           Map.take(params, ["submission_id", "note", "correction"])
         ) do
      {:ok, feedback, :created} ->
        conn |> put_status(:created) |> json(%{feedback: feedback})

      {:ok, feedback, :existing} ->
        json(conn, %{feedback: feedback})

      {:error, :invalid_feedback} ->
        PublicError.render(
          conn,
          :unprocessable_entity,
          "invalid_feedback",
          "Write a note of up to 2000 characters. A correction is optional and has the same limit."
        )

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "job_not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, :job_not_ready_for_feedback} ->
        PublicError.render(
          conn,
          :conflict,
          "job_not_ready_for_feedback",
          "Feedback can be given once the task has a result."
        )

      {:error, :feedback_conflict} ->
        PublicError.render(
          conn,
          :conflict,
          "feedback_conflict",
          "This feedback identity already holds a different note."
        )

      {:error, {:feedback_outcome_unknown, _reason}} ->
        PublicError.render(
          conn,
          :service_unavailable,
          "feedback_outcome_unknown",
          "The feedback could not be confirmed. Retry with the same feedback identity.",
          retryable: true
        )

      {:error, reason} ->
        Logger.error("feedback save failed: #{inspect(reason)}")

        PublicError.render(
          conn,
          :internal_server_error,
          "feedback_save_failed",
          "The feedback could not be saved."
        )
    end
  end
end
