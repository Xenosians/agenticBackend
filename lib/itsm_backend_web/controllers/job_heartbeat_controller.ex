defmodule ItsmBackendWeb.JobHeartbeatController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.Jobs
  alias ItsmBackend.RuntimeConfig

  # ------------------------------------------------------------
  # POST heartbeat
  #
  # A heartbeat is not a completion.
  #
  # It only proves that the exact durable AI execution attempt
  # is still alive and therefore may continue holding its
  # processing lease.
  # ------------------------------------------------------------

  def heartbeat(
        conn,
        %{
          "id" => job_id
        }
      ) do
    if authorized?(conn) do
      handle_heartbeat(
        conn,
        job_id,
        conn.body_params
      )
    else
      unauthorized(conn)
    end
  end

  def heartbeat(
        conn,
        _params
      ) do
    invalid_heartbeat(conn)
  end

  # ------------------------------------------------------------
  # Payload validation
  # ------------------------------------------------------------

  defp handle_heartbeat(
         conn,
         job_id,
         %{
           "attempt" => attempt
         }
       )
       when is_integer(attempt) and
              attempt > 0 do
    lease_seconds =
      RuntimeConfig
      .queue_worker!()
      .lease_seconds

    case Jobs.renew_processing_lease(
           job_id,
           attempt,
           lease_seconds
         ) do
      {:ok, job} ->
        conn
        |> put_status(:ok)
        |> json(%{
          job_id:
            job.id,
          attempt:
            job.attempts,
          status:
            job.status,
          lease_expires_at:
            job.lease_expires_at
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error:
            "job_not_found"
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
          error:
            "stale_attempt",
          current_attempt:
            current_attempt,
          received_attempt:
            received_attempt
        })

      {:error,
       {
         :job_not_processing,
         status
       }} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error:
            "job_not_processing",
          status:
            status
        })

      {:error, :lease_expired} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error:
            "lease_expired"
        })

      {:error, :lease_missing} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error:
            "lease_missing"
        })

      {:error, reason} ->
        conn
        |> put_status(
          :internal_server_error
        )
        |> json(%{
          error:
            "heartbeat_failed",
          reason:
            inspect(reason)
        })
    end
  end

  defp handle_heartbeat(
         conn,
         _job_id,
         _payload
       ) do
    invalid_heartbeat(conn)
  end

  # ------------------------------------------------------------
  # Invalid payload
  # ------------------------------------------------------------

  defp invalid_heartbeat(conn) do
    conn
    |> put_status(
      :unprocessable_entity
    )
    |> json(%{
      error:
        "invalid_heartbeat"
    })
  end

  # ------------------------------------------------------------
  # Unauthorized
  # ------------------------------------------------------------

  defp unauthorized(conn) do
    conn
    |> put_status(
      :unauthorized
    )
    |> json(%{
      error:
        "unauthorized"
    })
  end

  # ------------------------------------------------------------
  # Internal service authentication
  # ------------------------------------------------------------

  defp authorized?(conn) do
    expected =
      RuntimeConfig.internal_job_token!()

    provided =
      conn
      |> get_req_header(
        "x-internal-token"
      )
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
