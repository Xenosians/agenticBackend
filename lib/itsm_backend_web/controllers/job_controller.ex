defmodule ItsmBackendWeb.JobController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.Jobs

  def create(
        conn,
        params
      ) do
    case Jobs.create(params) do
      {:ok, job} ->
        conn
        |> put_status(:accepted)
        |> json(%{
          job_id: job.id,
          status: job.status
        })

      {:error, {:invalid_field, field}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "invalid_request",
          field: field
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "job_creation_failed",
          reason: inspect(reason)
        })
    end
  end

  def show(
        conn,
        %{"id" => job_id}
      ) do
    case Jobs.get(job_id) do
      {:ok, job} ->
        json(
          conn,
          job_response(job)
        )

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "job_not_found"
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "job_lookup_failed",
          reason: inspect(reason)
        })
    end
  end

  defp job_response(job) do
    %{
      job_id: job.id,
      user_id: job.user_id,
      conversation_id: job.conversation_id,
      message: job.message,
      status: job.status,
      attempts: job.attempts,
      created_at: job.created_at,
      claimed_at: job.claimed_at,
      lease_expires_at: job.lease_expires_at,
      completed_at: job.completed_at,
      selected_agent: job.selected_agent,
      proposed_tool: job.proposed_tool,
      result: job.result,
      error: job.error
    }
  end
end
