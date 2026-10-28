defmodule ItsmBackendWeb.WorkflowController do
  @moduledoc """
  Saved workflows for the signed-in owner (SRS 1.9 FR-084). Every change and
  every run needs CSRF for cookie sessions; another owner's workflow is
  reported exactly like a missing one.
  """
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  require Logger

  alias ItsmBackend.Workflows
  alias ItsmBackend.Jobs.PublicContract
  alias ItsmBackendWeb.{AuthRequest, PublicError}

  request_contract(:index, [])
  request_contract(:show, [])
  request_contract(:create, required_body: ["name", "definition", "layout"])
  request_contract(:update, required_body: ["name", "definition", "layout", "base_version"])
  request_contract(:delete, [])
  request_contract(:run, required_body: ["version", "submission_id", "message"])
  request_contract(:runs, [])

  def index(conn, _params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      case Workflows.list(ctx.user) do
        {:ok, workflows} -> json(conn, %{workflows: workflows})
        {:error, reason} -> unavailable(conn, reason)
      end
    else
      {:error, conn} -> conn
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      respond(conn, Workflows.get(ctx.user, id), :ok)
    else
      {:error, conn} -> conn
    end
  end

  def create(conn, params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      respond(
        conn,
        Workflows.create(ctx.user, Map.take(params, ~w(name definition layout))),
        :created
      )
    else
      {:error, conn} -> conn
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      input = Map.take(params, ~w(name definition layout base_version))
      respond(conn, Workflows.update(ctx.user, id, input), :ok)
    else
      {:error, conn} -> conn
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      case Workflows.archive(ctx.user, id) do
        :ok -> json(conn, %{archived: true, workflow_id: id})
        error -> respond(conn, error, :ok)
      end
    else
      {:error, conn} -> conn
    end
  end

  def run(conn, %{"id" => id} = params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      case Workflows.run(ctx.user, id, Map.take(params, ~w(version submission_id message))) do
        {:ok, workflow, job, submission} ->
          case PublicContract.build_create_response(
                 job.id,
                 job.status,
                 submission,
                 job.workflow_contract,
                 job.workflow_contract_hash
               ) do
            {:ok, response} ->
              conn
              |> put_status(:accepted)
              |> json(
                Map.merge(response, %{
                  "chat_id" => job.conversation_id,
                  "workflow_id" => workflow["workflow_id"],
                  "workflow_version" => workflow["version"]
                })
              )

            {:error, reason} ->
              unavailable(conn, reason)
          end

        error ->
          respond(conn, error, :accepted)
      end
    else
      {:error, conn} -> conn
    end
  end

  def runs(conn, %{"id" => id}) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      case Workflows.runs(ctx.user, id) do
        {:ok, runs} -> json(conn, %{runs: runs})
        error -> respond(conn, error, :ok)
      end
    else
      {:error, conn} -> conn
    end
  end

  defp respond(conn, {:ok, workflow}, status),
    do: conn |> put_status(status) |> json(%{workflow: workflow})

  defp respond(conn, {:error, :not_found}, _status),
    do:
      PublicError.render(conn, :not_found, "workflow_not_found", "This workflow does not exist.")

  defp respond(conn, {:error, reason}, _status)
       when reason in [:invalid_workflow, :invalid_run] do
    PublicError.render(
      conn,
      :unprocessable_entity,
      "invalid_workflow",
      "Check the workflow's name, steps, dependencies and canvas positions."
    )
  end

  defp respond(conn, {:error, :version_conflict}, _status) do
    PublicError.render(
      conn,
      :conflict,
      "workflow_version_conflict",
      "This workflow changed since you opened it. Reload it before saving or running."
    )
  end

  defp respond(conn, {:error, :submission_conflict}, _status) do
    PublicError.render(
      conn,
      :conflict,
      "submission_conflict",
      "This run identity already belongs to a different request. Start a new run instead."
    )
  end

  defp respond(conn, {:error, reason}, _status), do: unavailable(conn, reason)

  defp unavailable(conn, reason) do
    Logger.error("workflow request failed: #{inspect(reason, limit: 5)}")

    PublicError.render(
      conn,
      :service_unavailable,
      "workflow_unavailable",
      "The workflow could not be confirmed. Reload before trying again; a run retried with the same identity is never duplicated.",
      retryable: true
    )
  end
end
