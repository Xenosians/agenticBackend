defmodule ItsmBackend.AIClient do
  @callback run(user_id :: String.t(), message :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback approve(approval_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback health() ::
              {:ok, map()} | {:error, term()}
end
