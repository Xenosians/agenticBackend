defmodule ItsmBackendWeb.JobHeartbeatController do
  use ItsmBackendWeb, :controller

  use ItsmBackendWeb.RequestContract

  request_contract(:heartbeat,
    required_body: ["attempt"]
  )

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackendWeb.LeaseRenewal

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
    case LeaseRenewal.renew(job_id, attempt) do
      {:ok, body} ->
        conn
        |> put_status(:ok)
        |> json(body)

      {:error, status, body} ->
        conn
        |> put_status(status)
        |> json(body)
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
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_heartbeat"
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
      RuntimeConfig.internal_job_token!()

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
