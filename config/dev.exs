import Config

# ------------------------------------------------------------
# Phoenix endpoint
# ------------------------------------------------------------

config :itsm_backend, ItsmBackendWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: 4000
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "ucP/Y1R0Cryu9mcyo9b6IIOACMt9/Ect5QePUfHazR2vAv0FJA0sRGHudI8WeKTX",
  watchers: []

# ------------------------------------------------------------
# Development browser frontend
# ------------------------------------------------------------

config :itsm_backend,
       :cors,
       allowed_origins: [
         "http://localhost:8080",
         "http://127.0.0.1:8080"
       ]

# ------------------------------------------------------------
# Development AI service
# ------------------------------------------------------------

config :itsm_backend,
       :ai_service,
       base_url: "http://127.0.0.1:8000",
       run_timeout_ms: 300_000,
       execute_timeout_ms: 10_000,
       health_timeout_ms: 5_000,
       ready_timeout_ms: 5_000

# ------------------------------------------------------------
# Development durable queue worker
# ------------------------------------------------------------

config :itsm_backend,
       :queue_worker,
       enabled: true,
       poll_interval_ms: 1_000,
       lease_seconds: 300

# ------------------------------------------------------------
# Development runtime
# ------------------------------------------------------------

config :itsm_backend,
  dev_routes: true

config :logger,
       :default_formatter,
       format: "[$level] $message\n"

config :phoenix,
       :stacktrace_depth,
       20

config :phoenix,
       :plug_init_mode,
       :runtime

config :swoosh,
       :api_client,
       false
