defmodule ItsmBackendWeb.JobCompletionController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.CompletionContract

  # ------------------------------------------------------------
  # POST completion callback
  # ------------------------------------------------------------

  def complete(
        conn,
        %{
          "id" => job_id
        }
      ) do
    if authorized?(conn) do
      validate_and_handle_completion(
        conn,
        job_id,
        conn.body_params
      )
    else
      unauthorized(conn)
    end
  end

  def complete(
        conn,
        _params
      ) do
    invalid_completion_payload(conn)
  end

  # ------------------------------------------------------------
  # Contract validation
  # ------------------------------------------------------------

  defp validate_and_handle_completion(
         conn,
         job_id,
         body_params
       ) do
    case CompletionContract.validate(body_params) do
      {:ok,
       %{
         "attempt" => attempt,
         "status" => status
       } = completion} ->
        handle_completion(
          conn,
          job_id,
          attempt,
          status,
          completion
        )

      {:error, _reason} ->
        invalid_completion_payload(conn)
    end
  end

  # ------------------------------------------------------------
  # Completion handling
  # ------------------------------------------------------------

  defp handle_completion(
         conn,
         job_id,
         attempt,
         status,
         completion
       ) do
    case Jobs.apply_completion(
           job_id,
           attempt,
           status,
           completion
         ) do
      {:ok, job, disposition} ->
        send_completion_ack(
          conn,
          job.id,
          job.status,
          disposition
        )

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "job_not_found"
        })

      {:error,
       {
         :stale_attempt,
         current_attempt,
         received_attempt
       }} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "stale_attempt",
          current_attempt: current_attempt,
          received_attempt: received_attempt
        })

      {:error,
       {
         :invalid_completion_state,
         current_status,
         received_status
       }} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "invalid_completion_state",
          current_status: current_status,
          received_status: received_status
        })

      {:error,
       {
         :invalid_completion_status,
         received_status
       }} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "invalid_completion_status",
          received_status: received_status
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "completion_failed",
          reason: inspect(reason)
        })
    end
  end

  # ------------------------------------------------------------
  # Completion acknowledgement
  # ------------------------------------------------------------

  defp send_completion_ack(
         conn,
         job_id,
         status,
         disposition
       ) do
    case CompletionContract.build_ack(
           job_id,
           status,
           disposition
         ) do
      {:ok, acknowledgement} ->
        conn
        |> put_status(:ok)
        |> json(acknowledgement)

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "completion_ack_contract_violation",
          reason: inspect(reason)
        })
    end
  end

  # ------------------------------------------------------------
  # Invalid payload
  # ------------------------------------------------------------

  defp invalid_completion_payload(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_completion_payload"
    })
  end

  # ------------------------------------------------------------
  # Unauthorized
  # ------------------------------------------------------------

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{
      error: "unauthorized"
    })
  end

  # ------------------------------------------------------------
  # Internal service authentication
  # ------------------------------------------------------------

  defp authorized?(conn) do
    expected =
      Application.fetch_env!(
        :itsm_backend,
        :internal_job_token
      )

    provided =
      conn
      |> get_req_header("x-internal-token")
      |> List.first()

    secure_match?(
      provided,
      expected
    )
  end

  defp secure_match?(
         provided,
         expected
       )
       when is_binary(provided) and
              is_binary(expected) and
              byte_size(provided) ==
                byte_size(expected) do
    Plug.Crypto.secure_compare(
      provided,
      expected
    )
  end

  defp secure_match?(
         _provided,
         _expected
       ) do
    false
  end
end
