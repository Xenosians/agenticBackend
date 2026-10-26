defmodule ItsmBackendWeb.OperationsController do
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract
  request_contract(:index, optional_query: ["limit"])
  alias ItsmBackend.Jobs.Operations
  alias ItsmBackendWeb.{AuthRequest, PublicError}

  def index(conn, params) do
    case AuthRequest.require_authenticated(conn) do
      {:ok, conn, ctx} ->
        with {:ok, limit} <- limit(params),
             {:ok, snapshot} <- Operations.snapshot(ctx.user["user_id"], limit) do
          json(conn, snapshot)
        else
          {:error, :invalid_limit} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_limit"})

          _ ->
            PublicError.render(
              conn,
              :service_unavailable,
              "operations_unavailable",
              "Operations could not be loaded.",
              retryable: true
            )
        end

      {:error, conn} ->
        conn
    end
  end

  defp limit(params) do
    case Map.get(params, "limit", "25") do
      input when is_binary(input) ->
        case Integer.parse(input) do
          {value, ""} when value in 1..100 -> {:ok, value}
          _ -> {:error, :invalid_limit}
        end

      _ ->
        {:error, :invalid_limit}
    end
  end
end
