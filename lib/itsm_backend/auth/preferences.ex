defmodule ItsmBackend.Auth.Preferences do
  @moduledoc "Owner-controlled optional task completion notifications."

  alias ItsmBackend.Auth.SurrealStore

  def get(user_id) do
    with {:ok, user} when is_map(user) <- SurrealStore.get_user(user_id) do
      from_user(user)
    else
      _ -> {:error, :preferences_unavailable}
    end
  end

  def save(user_id, %{"task_completed" => enabled} = input)
      when is_boolean(enabled) and map_size(input) == 1 do
    # Refuse to overwrite a malformed stored preference as if it were valid.
    with {:ok, _} <- get(user_id) do
      case SurrealStore.set_task_completed_preference(user_id, enabled) do
        {:ok, user} when is_map(user) -> confirm(user, enabled)
        _ -> confirm_readback(user_id, enabled)
      end
    end
  end

  def save(_, _), do: {:error, :invalid_preferences}

  def from_user(user) when is_map(user) do
    case Map.fetch(user, "notification_preferences") do
      :error -> {:ok, %{"task_completed" => true}}
      {:ok, nil} -> {:error, :invalid_stored_preferences}
      {:ok, preferences} when is_map(preferences) -> decode(preferences)
      _ -> {:error, :invalid_stored_preferences}
    end
  end

  def from_user(_), do: {:error, :invalid_stored_preferences}

  defp decode(preferences) do
    case Map.fetch(preferences, "task_completed") do
      :error -> {:ok, %{"task_completed" => true}}
      {:ok, enabled} when is_boolean(enabled) -> {:ok, %{"task_completed" => enabled}}
      _ -> {:error, :invalid_stored_preferences}
    end
  end

  defp confirm(user, enabled) do
    case from_user(user) do
      {:ok, %{"task_completed" => ^enabled} = preferences} -> {:ok, preferences}
      _ -> {:error, :preferences_save_unconfirmed}
    end
  end

  defp confirm_readback(user_id, enabled) do
    case get(user_id) do
      {:ok, %{"task_completed" => ^enabled} = preferences} -> {:ok, preferences}
      _ -> {:error, :preferences_save_unconfirmed}
    end
  end
end
