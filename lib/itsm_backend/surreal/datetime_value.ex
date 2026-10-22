defmodule ItsmBackend.Surreal.DateTimeValue do
  @moduledoc "Explicit trusted datetime parameter; ordinary strings remain text."
  @enforce_keys [:value]
  defstruct [:value]
end
