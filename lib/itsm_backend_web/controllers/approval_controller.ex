defmodule ItsmBackendWeb.ApprovalController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.RuntimeConfig

  def approve(
        conn,
        %{"approval_id" => approval_id}
      ) do
    ai_client =
      RuntimeConfig.ai_client!()

    case ai_client.approve(approval_id) do
      {:ok, result} ->
        json(
          conn,
          result
        )

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{
          status: "error",
          error: inspect(reason)
        })
    end
  end
end
