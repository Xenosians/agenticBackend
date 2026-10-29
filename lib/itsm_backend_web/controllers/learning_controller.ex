defmodule ItsmBackendWeb.LearningController do
  @moduledoc """
  Learning for the signed-in owner (FR-087/088).

  Reads the owner's training catalog, checks one selection, and starts, lists
  or cancels candidate SFT runs. A run starts only from the exact ready check
  the owner saw, never changes what serves requests and is never promoted here.
  The owner always comes from the authenticated session, and only the exact
  fields below cross to the AI service.
  """
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackend.Learning.PublicContract
  alias ItsmBackendWeb.{AuthRequest, PublicError}

  @selection_fields ~w(method role tuning model_id dataset_id dataset_sha256)
  @selection_keys Enum.sort(@selection_fields)
  @run_fields @selection_fields ++ ~w(preflight_sha256 submission_id)
  @run_keys Enum.sort(@run_fields)
  @run_id ~r/\A[0-9a-f]{32}\z/
  # AI refusal codes that are safe and useful to show the owner.
  @public_refusals ~w(
    invalid_learning_request
    learning_resource_unavailable
    learning_dataset_not_training
    learning_dataset_changed
    learning_dataset_superseded
    learning_training_membership_invalid
    learning_check_changed
    learning_run_not_ready
  )

  request_contract(:index, [])
  request_contract(:preflight, required_body: @selection_fields)
  request_contract(:runs, [])
  request_contract(:resolve_run, required_query: ["submission_id"])
  request_contract(:start_run, required_body: @run_fields)
  request_contract(:cancel_run, [])

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

  def runs(conn, params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      if map_size(params) == 0 do
        forward(conn, "/internal/v1/learning/runs", %{owner: ctx.user["user_id"]})
      else
        refused(conn, "invalid_learning_request")
      end
    else
      {:error, conn} -> conn
    end
  end

  def start_run(conn, params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      if map_size(conn.query_params) == 0 and Enum.sort(Map.keys(params)) == @run_keys do
        conn
        |> register_before_send(&record_start_refusal(&1, ctx.user, params))
        |> forward("/internal/v1/learning/runs/start", %{owner: ctx.user["user_id"], run: params})
      else
        refused(conn, "invalid_learning_request")
      end
    else
      {:error, conn} -> conn
    end
  end

  def resolve_run(conn, %{"submission_id" => submission} = params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      if map_size(params) == 1 and is_binary(submission) and Regex.match?(@run_id, submission) do
        forward(conn, "/internal/v1/learning/runs/resolve", %{
          owner: ctx.user["user_id"],
          submission_id: submission
        })
      else
        refused(conn, "invalid_learning_request")
      end
    else
      {:error, conn} -> conn
    end
  end

  def resolve_run(conn, _params) do
    with {:ok, conn, _ctx} <- AuthRequest.require_authenticated(conn) do
      refused(conn, "invalid_learning_request")
    else
      {:error, conn} -> conn
    end
  end

  def cancel_run(conn, %{"id" => run_id} = params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      if map_size(conn.query_params) == 0 and map_size(params) == 1 and
           Regex.match?(@run_id, run_id) do
        forward(conn, "/internal/v1/learning/runs/cancel", %{
          owner: ctx.user["user_id"],
          run_id: run_id
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
        if valid_receipt?(path, response, body) do
          json(conn, response)
        else
          unavailable(conn)
        end

      {:ok, %{status: 409, body: %{"detail" => "learning_host_busy"}}} ->
        PublicError.render(
          conn,
          :conflict,
          "learning_host_busy",
          "Another candidate run is training on this host. Try again when it finishes.",
          retryable: true
        )

      {:ok, %{status: 409, body: %{"detail" => "learning_submission_conflict"}}} ->
        PublicError.render(
          conn,
          :conflict,
          "learning_submission_conflict",
          "This run identity belongs to another request. Reconcile the original start before continuing."
        )

      {:ok, %{status: 503, body: %{"detail" => code}}}
      when code in ~w(learning_run_outcome_unknown learning_registry_unavailable) ->
        PublicError.render(
          conn,
          :service_unavailable,
          code,
          "The original run could not be reconciled. Keep its identity and check again before starting another run.",
          retryable: true
        )

      {:ok, %{status: 404, body: %{"detail" => "learning_run_unavailable"}}} ->
        PublicError.render(
          conn,
          :not_found,
          "learning_run_unavailable",
          "That run is not available. Refresh the run list."
        )

      {:ok, %{status: 422, body: %{"detail" => code}}} when code in @public_refusals ->
        refused(conn, code)

      {:ok, %{status: 422}} ->
        refused(conn, "invalid_learning_request")

      _ ->
        unavailable(conn)
    end
  end

  defp valid_receipt?("/internal/v1/learning/catalog", response, _body),
    do: PublicContract.valid_catalog?(response)

  defp valid_receipt?("/internal/v1/learning/preflight", response, %{selection: selection}),
    do: PublicContract.valid_preflight?(response, selection)

  defp valid_receipt?("/internal/v1/learning/runs", response, _body),
    do: PublicContract.valid_runs?(response)

  defp valid_receipt?("/internal/v1/learning/runs/start", response, %{run: request}),
    do: PublicContract.valid_started_run?(response, request)

  defp valid_receipt?("/internal/v1/learning/runs/resolve", response, %{submission_id: submission}),
       do: PublicContract.valid_resolved_run?(response, submission)

  defp valid_receipt?("/internal/v1/learning/runs/cancel", response, %{run_id: run_id}),
    do: PublicContract.valid_cancelled_run?(response, run_id)

  defp unavailable(conn) do
    PublicError.render(
      conn,
      :service_unavailable,
      "learning_service_unavailable",
      "Learning could not be reached. Refresh to check again.",
      retryable: true
    )
  end

  defp refused(conn, code) do
    PublicError.render(
      conn,
      :unprocessable_entity,
      code,
      "Learning refused this selection. Refresh your inputs and try again."
    )
  end

  # Recorded before the refusal is sent (the response body is gone afterwards),
  # so the owner's next read already sees the released request.
  defp record_start_refusal(%{status: status} = conn, user, request) when status in [409, 422] do
    case Jason.decode(conn.resp_body || "") do
      {:ok, %{"error" => code}} when code in @public_refusals or code == "learning_host_busy" ->
        ItsmBackend.SubmissionIntents.record_rejection(
          user,
          "learning",
          "candidate",
          request,
          code
        )

      _ ->
        :ok
    end

    conn
  end

  defp record_start_refusal(conn, _, _), do: conn
end
