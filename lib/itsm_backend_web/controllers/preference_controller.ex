defmodule ItsmBackendWeb.PreferenceController do
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  request_contract(:show, [])
  request_contract(:update, optional_body: ["task_completed", "theme", "accent", "pinned_views"])

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
      "Send at least one setting: task_completed true or false, theme dark, light or system, one of the offered accents, or pinned_views as a list of offered dashboards."
    )
  end

  defp unavailable(conn, code) do
    PublicError.render(
      conn,
      :service_unavailable,
      code,
      "The setting could not be confirmed. Reload Settings before changing it again.",
      retryable: true
    )
  end
end
