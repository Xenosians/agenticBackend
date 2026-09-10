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

# ------------------------------------------------------------
# Phoenix server
#
# Development/test ports live in their environment-specific
# configuration. Production has no embedded port fallback.
# ------------------------------------------------------------

if System.get_env("PHX_SERVER") do
  config :itsm_backend,
         ItsmBackendWeb.Endpoint,
         server: true
end

case {
  config_env(),
  System.get_env("PORT")
} do
  {:prod, _value} ->
    value =
      required_env.("PORT")

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

  {_environment, nil} ->
    :ok

  {_environment, value} ->
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

# ------------------------------------------------------------
# AI service
#
# Development/test defaults live in their environment-specific
# configuration. Production requires every transport value.
# Non-production environments may override individual values.
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
#
# Development/test defaults live in their environment-specific
# configuration. Production requires every worker setting.
# Non-production environments may override individual values.
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
#
# Development/test defaults live in their environment-specific
# configuration. Production must explicitly supply its origins.
#
# Multiple origins are comma separated.
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
# Production
# ------------------------------------------------------------

if config_env() == :prod do
  secret_key_base =
    required_env.("SECRET_KEY_BASE")

  host =
    required_env.("PHX_HOST")

  config :itsm_backend,
         :dns_cluster_query,
         System.get_env("DNS_CLUSTER_QUERY")

  # ----------------------------------------------------------
  # Production SurrealDB
  #
  # No deployment or credential defaults are permitted here.
  # RuntimeConfig.surrealdb!/0 performs final semantic
  # validation after runtime environment ingress.
  # ----------------------------------------------------------

  config :itsm_backend,
         :surrealdb,
         url: required_env.("SURREALDB_URL"),
         namespace: required_env.("SURREALDB_NAMESPACE"),
         database: required_env.("SURREALDB_DATABASE"),
         username: required_env.("SURREALDB_USERNAME"),
         password: required_env.("SURREALDB_PASSWORD")

  config :itsm_backend,
         ItsmBackendWeb.Endpoint,
         url: [
           host: host,
           port: 443,
           scheme: "https"
         ],
         http: [
           ip: {
             0,
             0,
             0,
             0,
             0,
             0,
             0,
             0
           }
         ],
         secret_key_base: secret_key_base
end
