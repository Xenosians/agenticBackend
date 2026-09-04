defmodule ItsmBackendWeb.JobCompletionController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.Jobs

  # ------------------------------------------------------------
  # POST completion callback
  # ------------------------------------------------------------

  def complete(
        conn,
        %{
          "id" => job_id,
          "attempt" => attempt,
          "status" => status
        } = params
      )
      when is_integer(attempt) do
    if authorized?(conn) do
      handle_completion(
        conn,
        job_id,
        attempt,
        status,
        params
      )
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{
        error: "unauthorized"
      })
    end
  end

  def complete(
        conn,
        _params
      ) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_completion_payload"
    })
  end

  # ------------------------------------------------------------
  # Completion handling
  # ------------------------------------------------------------

  defp handle_completion(
         conn,
         job_id,
         attempt,
         status,
         params
       ) do
    case Jobs.apply_completion(
           job_id,
           attempt,
           status,
           params
         ) do
      {:ok, job, disposition} ->
        conn
        |> put_status(:ok)
        |> json(%{
          job_id: job.id,
          status: job.status,
          acknowledgement: Atom.to_string(disposition)
        })

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
