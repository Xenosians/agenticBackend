defmodule ItsmBackendWeb.PreferenceController do
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  request_contract(:show, [])
  request_contract(:update, required_body: ["task_completed"])

  alias ItsmBackend.Auth.Preferences
  alias ItsmBackendWeb.{AuthRequest, PublicError}

  def show(conn, params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      case if(map_size(params) == 0,
             do: Preferences.get(ctx.user["user_id"]),
             else: {:error, :invalid_preferences}
           ) do
        {:ok, preferences} -> json(conn, %{preferences: preferences})
        {:error, :invalid_preferences} -> invalid(conn)
        _ -> unavailable(conn, "preferences_unavailable")
      end
    else
      {:error, conn} -> conn
    end
  end

  def update(conn, params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      case if(map_size(conn.query_params) == 0,
             do: Preferences.save(ctx.user["user_id"], params),
             else: {:error, :invalid_preferences}
           ) do
        {:ok, preferences} ->
          json(conn, %{preferences: preferences})

        {:error, :invalid_preferences} ->
          invalid(conn)

        _ ->
          unavailable(conn, "preferences_save_unconfirmed")
      end
    else
      {:error, conn} -> conn
    end
  end

  defp invalid(conn) do
    PublicError.render(
      conn,
      :unprocessable_entity,
      "invalid_preferences",
      "Choose true or false for task completion emails."
    )
  end

  defp unavailable(conn, code) do
    PublicError.render(
      conn,
      :service_unavailable,
      code,
      "The notification preference could not be confirmed. Reload Account before changing it again.",
      retryable: true
    )
  end
end
