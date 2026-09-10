import Config

# ------------------------------------------------------------
# Phoenix server
# ------------------------------------------------------------

if System.get_env("PHX_SERVER") do
  config :itsm_backend,
         ItsmBackendWeb.Endpoint,
         server: true
end

config :itsm_backend,
       ItsmBackendWeb.Endpoint,
       http: [
         port:
           String.to_integer(
             System.get_env(
               "PORT",
               "4000"
             )
           )
       ]

# ------------------------------------------------------------
# AI service
# ------------------------------------------------------------

ai_service_base_url =
  case {
    config_env(),
    System.get_env("AI_SERVICE_URL")
  } do
    {:prod, nil} ->
      raise """
      environment variable AI_SERVICE_URL is missing.
      """

    {_environment, nil} ->
      "http://127.0.0.1:8000"

    {_environment, value} ->
      value
  end

config :itsm_backend,
       :ai_service,
       base_url: ai_service_base_url,
       run_timeout_ms:
         System.get_env(
           "AI_RUN_TIMEOUT_MS",
           "300000"
         ),
       execute_timeout_ms:
         System.get_env(
           "AI_EXECUTE_TIMEOUT_MS",
           "10000"
         ),
       health_timeout_ms:
         System.get_env(
           "AI_HEALTH_TIMEOUT_MS",
           "5000"
         ),
       ready_timeout_ms:
         System.get_env(
           "AI_READY_TIMEOUT_MS",
           "5000"
         )

# ------------------------------------------------------------
# Durable queue worker
# ------------------------------------------------------------

queue_worker_default_enabled =
  if config_env() == :test do
    "false"
  else
    "true"
  end

config :itsm_backend,
       :queue_worker,
       enabled:
         System.get_env(
           "QUEUE_WORKER_ENABLED",
           queue_worker_default_enabled
         ),
       poll_interval_ms:
         System.get_env(
           "QUEUE_WORKER_POLL_INTERVAL_MS",
           "1000"
         ),
       lease_seconds:
         System.get_env(
           "QUEUE_WORKER_LEASE_SECONDS",
           "300"
         )

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
# Production
# ------------------------------------------------------------

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      """

  config :itsm_backend,
         :dns_cluster_query,
         System.get_env("DNS_CLUSTER_QUERY")

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

  config :itsm_backend,
         :surrealdb,
         url:
           System.get_env(
             "SURREALDB_URL",
             "http://127.0.0.1:8001"
           ),
         namespace:
           System.get_env(
             "SURREALDB_NAMESPACE",
             "itsm"
           ),
         database:
           System.get_env(
             "SURREALDB_DATABASE",
             "itsm"
           ),
         username:
           System.get_env(
             "SURREALDB_USERNAME",
             "root"
           ),
         password:
           System.get_env(
             "SURREALDB_PASSWORD",
             "root"
           )
end
