defmodule ItsmBackendWeb.ApprovalController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.RuntimeConfig

  def approve(
        conn,
        %{"approval_id" => approval_id} = params
      ) do
    ai_client =
      RuntimeConfig.ai_client!()

    # A destructive action's exact target name, typed by the owner. The AI
    # approval authority checks it; a mismatch leaves the approval pending.
    confirm_name = Map.get(params, "confirm_name")

    case ai_client.approve(approval_id, confirm_name) do
      {:ok, result} ->
        json(
          conn,
          result
        )

      {:error, {:ai_service_error, 409, %{"detail" => %{"code" => code, "message" => message}}}}
      when code in ["confirmation_required", "confirmation_mismatch"] ->
        conn
        |> put_status(:conflict)
        |> json(%{error: code, message: message})

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
