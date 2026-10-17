defmodule ItsmBackend.Surreal.Session do
  @moduledoc """
  Cached SurrealDB session token for RPC requests.

  Basic authentication makes SurrealDB verify the password hash on every
  request, which costs about 25 ms each. Under concurrent load those checks
  queue up behind each other until requests time out. A signed-in token is
  verified as a signature instead (about 1 ms).

  The token is cached in `:persistent_term`. It is renewed shortly before it
  expires, and right away when SurrealDB rejects it. If sign-in fails, the
  caller falls back to basic authentication, so token handling can never
  make storage less available than it was without it.
  """

  @key {__MODULE__, :token}
  @renew_margin_seconds 120
  @signin_timeout_ms 10_000

  @doc "Request authentication options: a cached bearer token, or basic auth as fallback."
  @spec auth(map()) :: {:bearer, String.t()} | {:basic, String.t()}
  def auth(config) do
    case cached(config) do
      {:ok, token} -> {:bearer, token}
      :none -> basic(config)
    end
  end

  @doc "Forget the cached token, for example after SurrealDB rejected it."
  @spec invalidate() :: :ok
  def invalidate do
    :persistent_term.erase(@key)
    :ok
  end

  defp basic(config), do: {:basic, "#{config.username}:#{config.password}"}

  defp cached(config) do
    now = System.system_time(:second)
    fingerprint = fingerprint(config)

    case :persistent_term.get(@key, nil) do
      {^fingerprint, token, expires_at} when expires_at - @renew_margin_seconds > now ->
        {:ok, token}

      _ ->
        signin(config, fingerprint, now)
    end
  end

  # A changed URL or user (for example in tests) must never reuse a token.
  defp fingerprint(config), do: :erlang.phash2({config.url, config.username, config.password})

  defp signin(config, fingerprint, now) do
    case Req.post("#{config.url}/signin",
           headers: [{"accept", "application/json"}],
           json: %{"user" => config.username, "pass" => config.password},
           receive_timeout: @signin_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"token" => token}}} when is_binary(token) and token != "" ->
        expires_at = token_expiry(token) || now + 600
        :persistent_term.put(@key, {fingerprint, token, expires_at})
        {:ok, token}

      _ ->
        :none
    end
  rescue
    _ -> :none
  end

  # Reads only the expiry claim; the server verifies the signature.
  defp token_expiry(token) do
    with [_header, claims, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(claims, padding: false),
         {:ok, %{"exp" => exp}} when is_integer(exp) <- Jason.decode(json) do
      exp
    else
      _ -> nil
    end
  end
end
