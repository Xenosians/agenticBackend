defmodule ItsmBackendWeb.AgentController do
  use ItsmBackendWeb, :controller

  def run(conn, %{"user_id" => user_id, "message" => message}) do
    ai_client = Application.fetch_env!(:itsm_backend, :ai_client)

    case ai_client.run(user_id, message) do
      {:ok, result} ->
        json(conn, result)

      {:error, :unsupported_request} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          status: "error",
          error: "unsupported_request"
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{
          status: "error",
          error: inspect(reason)
        })
    end
  end

  def run(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      status: "error",
      error: "user_id and message are required"
    })
  end
end
