defmodule ItsmBackend.Auth.Authorization do
  @moduledoc false

  def owns_resource?(%{"role" => "admin"}, _owner_user_id), do: true

  def owns_resource?(%{"user_id" => user_id}, owner_user_id)
      when is_binary(user_id) and is_binary(owner_user_id),
      do: user_id == owner_user_id

  def owns_resource?(_, _), do: false
end
