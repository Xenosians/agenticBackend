defmodule ItsmBackendWeb.LearningController do
  @moduledoc """
  Learning readiness for the signed-in owner (FR-087).

  Reads the owner's training catalog and checks one selection against the
  gates that still block a candidate run. Nothing here starts, loads or
  promotes a model. The owner always comes from the authenticated session,
  and only the exact selection fields cross to the AI service.
  """
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.{AuthRequest, PublicError}

  @selection_fields ~w(method role tuning model_id dataset_id dataset_sha256)
  @selection_keys Enum.sort(@selection_fields)
  # AI refusal codes that are safe and useful to show the owner.
  @public_refusals ~w(
    invalid_learning_request
    learning_resource_unavailable
    learning_dataset_not_training
    learning_dataset_changed
    learning_dataset_superseded
    learning_training_membership_invalid
  )

  request_contract(:index, [])
  request_contract(:preflight, required_body: @selection_fields)

  def index(conn, params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      if map_size(params) == 0 do
        forward(conn, "/internal/v1/learning/catalog", %{owner: ctx.user["user_id"]})
      else
        refused(conn, "invalid_learning_request")
      end
    else
      {:error, conn} -> conn
    end
  end

  def preflight(conn, params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      if map_size(conn.query_params) == 0 and Enum.sort(Map.keys(params)) == @selection_keys do
        forward(conn, "/internal/v1/learning/preflight", %{
          owner: ctx.user["user_id"],
          selection: params
        })
      else
        refused(conn, "invalid_learning_request")
      end
    else
      {:error, conn} -> conn
    end
  end

  defp forward(conn, path, body) do
    config = RuntimeConfig.ai_service!()

    case Req.post("#{config.base_url}#{path}",
           headers: [{"x-internal-token", RuntimeConfig.internal_job_token!()}],
           json: body,
           retry: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: response}} when is_map(response) ->
        json(conn, response)

      {:ok, %{status: 422, body: %{"detail" => code}}} when code in @public_refusals ->
        refused(conn, code)

      {:ok, %{status: 422}} ->
        refused(conn, "invalid_learning_request")

      _ ->
        PublicError.render(
          conn,
          :service_unavailable,
          "learning_service_unavailable",
          "Learning could not be reached. Refresh to check again.",
          retryable: true
        )
    end
  end

  defp refused(conn, code) do
    PublicError.render(
      conn,
      :unprocessable_entity,
      code,
      "Learning refused this selection. Refresh your inputs and try again."
    )
  end
end
