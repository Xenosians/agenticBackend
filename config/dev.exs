import Config

# For development, we disable any cache and enable
# debugging and code reloading.
config :itsm_backend, ItsmBackendWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1}
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
# Development SurrealDB
# ------------------------------------------------------------

config :itsm_backend,
       :surrealdb,
       url: "http://127.0.0.1:8001",
       namespace: "itsm",
       database: "itsm",
       username: "itsm_app",
       password: "itsm_dev_2026"

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
