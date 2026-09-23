import Config

# ------------------------------------------------------------
# Runtime environment helpers
# ------------------------------------------------------------

required_env = fn variable ->
  case System.get_env(variable) do
    nil ->
      raise """
      environment variable #{variable} is missing.
      """

    value ->
      if String.trim(value) == "" do
        raise """
        environment variable #{variable} must not be blank.
        """
      end

      value
  end
end

parse_positive_integer_env = fn variable, value ->
  normalized =
    String.trim(value)

  case Integer.parse(normalized) do
    {integer, ""}
    when integer > 0 ->
      integer

    _ ->
      raise """
      environment variable #{variable} must be a positive integer.
      """
  end
end

parse_public_url = fn variable, value ->
  normalized =
    String.trim(value)

  uri =
    URI.parse(normalized)

  valid_path? =
    uri.path in [
      nil,
      "",
      "/"
    ]

  if uri.scheme in [
       "http",
       "https"
     ] and
       is_binary(uri.host) and
       uri.host != "" and
       is_integer(uri.port) and
       uri.port > 0 and
       is_nil(uri.userinfo) and
       is_nil(uri.query) and
       is_nil(uri.fragment) and
       valid_path? do
    %{
      scheme: uri.scheme,
      host: uri.host,
      port: uri.port
    }
  else
    raise """
    environment variable #{variable} must be an HTTP(S) origin containing a valid host and port and no path, query, fragment, or credentials.
    """
  end
end

parse_bind_ip = fn variable, value ->
  normalized =
    value
    |> String.trim()
    |> String.to_charlist()

  case :inet.parse_address(normalized) do
    {:ok, address} ->
      address

    {:error, _reason} ->
      raise """
      environment variable #{variable} must be a valid IPv4 or IPv6 address.
      """
  end
end

# ------------------------------------------------------------
# Phoenix server
# ------------------------------------------------------------

if System.get_env("PHX_SERVER") do
  config :itsm_backend,
         ItsmBackendWeb.Endpoint,
         server: true
end

# Non-production environments own explicit endpoint defaults in
# dev.exs/test.exs and may override the listening port.
if config_env() != :prod do
  case System.get_env("PORT") do
    nil ->
      :ok

    value ->
      port =
        parse_positive_integer_env.(
          "PORT",
          value
        )

      config :itsm_backend,
             ItsmBackendWeb.Endpoint,
             http: [
               port: port
             ]
  end
end

# ------------------------------------------------------------
# AI service
# ------------------------------------------------------------

if config_env() == :prod do
  config :itsm_backend,
         :ai_service,
         base_url: required_env.("AI_SERVICE_URL"),
         run_timeout_ms: required_env.("AI_RUN_TIMEOUT_MS"),
         execute_timeout_ms: required_env.("AI_EXECUTE_TIMEOUT_MS"),
         health_timeout_ms: required_env.("AI_HEALTH_TIMEOUT_MS"),
         ready_timeout_ms: required_env.("AI_READY_TIMEOUT_MS")
else
  ai_service_overrides =
    [
      base_url: System.get_env("AI_SERVICE_URL"),
      run_timeout_ms: System.get_env("AI_RUN_TIMEOUT_MS"),
      execute_timeout_ms: System.get_env("AI_EXECUTE_TIMEOUT_MS"),
      health_timeout_ms: System.get_env("AI_HEALTH_TIMEOUT_MS"),
      ready_timeout_ms: System.get_env("AI_READY_TIMEOUT_MS")
    ]
    |> Enum.reject(fn {_key, value} ->
      is_nil(value)
    end)

  if ai_service_overrides != [] do
    config :itsm_backend,
           :ai_service,
           ai_service_overrides
  end
end

# ------------------------------------------------------------
# Durable queue worker
# ------------------------------------------------------------

if config_env() == :prod do
  config :itsm_backend,
         :queue_worker,
         enabled: required_env.("QUEUE_WORKER_ENABLED"),
         poll_interval_ms: required_env.("QUEUE_WORKER_POLL_INTERVAL_MS"),
         lease_seconds: required_env.("QUEUE_WORKER_LEASE_SECONDS")
else
  queue_worker_overrides =
    [
      enabled: System.get_env("QUEUE_WORKER_ENABLED"),
      poll_interval_ms: System.get_env("QUEUE_WORKER_POLL_INTERVAL_MS"),
      lease_seconds: System.get_env("QUEUE_WORKER_LEASE_SECONDS")
    ]
    |> Enum.reject(fn {_key, value} ->
      is_nil(value)
    end)

  if queue_worker_overrides != [] do
    config :itsm_backend,
           :queue_worker,
           queue_worker_overrides
  end
end

# ------------------------------------------------------------
# Internal service authentication
# ------------------------------------------------------------

internal_job_token =
  System.get_env("ITSM_INTERNAL_JOB_TOKEN")

normalized_internal_job_token =
  case internal_job_token do
    nil ->
      nil

    token ->
      String.trim(token)
  end

case {
  config_env(),
  normalized_internal_job_token
} do
  {:prod, nil} ->
    raise """
    environment variable ITSM_INTERNAL_JOB_TOKEN is missing.
    """

  {:prod, ""} ->
    raise """
    environment variable ITSM_INTERNAL_JOB_TOKEN must not be blank.
    """

  {_environment, nil} ->
    :ok

  {_environment, ""} ->
    :ok

  {_environment, token} ->
    config :itsm_backend,
           :internal_job_token,
           token
end

# ------------------------------------------------------------
# Browser frontend origins
# ------------------------------------------------------------

cors_allowed_origins =
  System.get_env("CORS_ALLOWED_ORIGINS")

case {
  config_env(),
  cors_allowed_origins
} do
  {:prod, nil} ->
    raise """
    environment variable CORS_ALLOWED_ORIGINS is missing.
    """

  {_environment, nil} ->
    :ok

  {_environment, value} ->
    origins =
      value
      |> String.split(
        ",",
        trim: true
      )
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if origins == [] do
      raise """
      environment variable CORS_ALLOWED_ORIGINS must contain at least one origin.
      """
    end

    config :itsm_backend,
           :cors,
           allowed_origins: origins
end

# ------------------------------------------------------------
# SurrealDB
# ------------------------------------------------------------

config :itsm_backend,
       :surrealdb,
       url: required_env.("SURREALDB_URL"),
       namespace: required_env.("SURREALDB_NAMESPACE"),
       database: required_env.("SURREALDB_DATABASE"),
       username: required_env.("SURREALDB_USERNAME"),
       password: required_env.("SURREALDB_PASSWORD")

# ------------------------------------------------------------
# Production endpoint
#
# PHX_PUBLIC_URL describes the externally visible origin.
# PORT describes the actual HTTP listener.
# PHX_BIND_IP describes the network interface to bind.
#
# These are intentionally independent deployment concerns.
# ------------------------------------------------------------

if config_env() == :prod do
  secret_key_base =
    required_env.("SECRET_KEY_BASE")

  public_url =
    required_env.("PHX_PUBLIC_URL")
    |> then(fn value ->
      parse_public_url.(
        "PHX_PUBLIC_URL",
        value
      )
    end)

  port =
    required_env.("PORT")
    |> then(fn value ->
      parse_positive_integer_env.(
        "PORT",
        value
      )
    end)

  bind_ip =
    required_env.("PHX_BIND_IP")
    |> then(fn value ->
      parse_bind_ip.(
        "PHX_BIND_IP",
        value
      )
    end)

  config :itsm_backend,
         :dns_cluster_query,
         System.get_env("DNS_CLUSTER_QUERY")

  config :itsm_backend,
         ItsmBackendWeb.Endpoint,
         url: [
           scheme: public_url.scheme,
           host: public_url.host,
           port: public_url.port
         ],
         http: [
           ip: bind_ip,
           port: port
         ],
         secret_key_base: secret_key_base
end
