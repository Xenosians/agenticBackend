import Config

# For development, we disable any cache and enable
# debugging and code reloading.
config :itsm_backend, ItsmBackendWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [
    ip: {127, 0, 0, 1}
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "ucP/Y1R0Cryu9mcyo9b6IIOACMt9/Ect5QePUfHazR2vAv0FJA0sRGHudI8WeKTX",
  watchers: []

# ------------------------------------------------------------
# Development SurrealDB
#
# These values describe the repository's local development
# infrastructure only. Application code consumes them exclusively
# through RuntimeConfig.surrealdb!/0.
# ------------------------------------------------------------

config :itsm_backend,
       :surrealdb,
       url: "http://127.0.0.1:8001",
       namespace: "itsm",
       database: "itsm",
       username: "itsm_app",
       password: "itsm_dev_2026"

# Enable dev routes for dashboard and mailbox.
config :itsm_backend,
  dev_routes: true

# Do not include metadata nor timestamps in development logs.
config :logger,
       :default_formatter,
       format: "[$level] $message\n"

# Set a higher stacktrace during development.
config :phoenix,
       :stacktrace_depth,
       20

# Initialize plugs at runtime for faster development compilation.
config :phoenix,
       :plug_init_mode,
       :runtime

# Disable swoosh api client as it is only required for
# production adapters.
config :swoosh,
       :api_client,
       false
