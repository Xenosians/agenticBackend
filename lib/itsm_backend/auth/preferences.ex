defmodule ItsmBackend.Auth.Preferences do
  @moduledoc """
  Owner-controlled settings: task completion emails and the workspace
  appearance (theme and accent). Each value comes from a fixed list, so a
  stored or submitted value outside it is refused, never defaulted.
  """

  alias ItsmBackend.Auth.SurrealStore

  @themes ~w(dark light system)
  @accents ~w(mono blue teal green amber rose violet)
  @defaults %{"task_completed" => true, "theme" => "dark", "accent" => "mono"}

  def get(user_id) do
    with {:ok, user} when is_map(user) <- SurrealStore.get_user(user_id) do
      from_user(user)
    else
      _ -> {:error, :preferences_unavailable}
    end
  end

  @doc "Saves only the settings sent; the others keep their saved values."
  def save(user_id, input) when is_map(input) and map_size(input) > 0 do
    with {:ok, changes} <- validate(input),
         # Refuse to overwrite a malformed stored preference as if it were valid.
         {:ok, _} <- get(user_id) do
      case SurrealStore.set_preferences(user_id, changes) do
        {:ok, user} when is_map(user) -> confirm(from_user(user), changes)
        _ -> confirm(get(user_id), changes)
      end
    end
  end

  def save(_, _), do: {:error, :invalid_preferences}

  def from_user(user) when is_map(user) do
    case Map.fetch(user, "notification_preferences") do
      :error -> {:ok, @defaults}
      {:ok, preferences} when is_map(preferences) -> decode(preferences)
      _ -> {:error, :invalid_stored_preferences}
    end
  end

  def from_user(_), do: {:error, :invalid_stored_preferences}

  defp decode(stored) do
    Enum.reduce_while(@defaults, {:ok, %{}}, fn {key, default}, {:ok, acc} ->
      case Map.fetch(stored, key) do
        :error ->
          {:cont, {:ok, Map.put(acc, key, default)}}

        {:ok, value} ->
          if valid?(key, value),
            do: {:cont, {:ok, Map.put(acc, key, value)}},
            else: {:halt, {:error, :invalid_stored_preferences}}
      end
    end)
  end

  defp validate(input) do
    if Enum.all?(input, fn {key, value} -> Map.has_key?(@defaults, key) and valid?(key, value) end),
       do: {:ok, input},
       else: {:error, :invalid_preferences}
  end

  defp valid?("task_completed", value), do: is_boolean(value)
  defp valid?("theme", value), do: value in @themes
  defp valid?("accent", value), do: value in @accents

  # A write is confirmed only when the saved settings read back as requested.
  defp confirm({:ok, preferences} = saved, changes) do
    if Map.take(preferences, Map.keys(changes)) == changes,
      do: saved,
      else: {:error, :preferences_save_unconfirmed}
  end

  defp confirm(_, _), do: {:error, :preferences_save_unconfirmed}
end
