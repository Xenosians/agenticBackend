import Config

# ------------------------------------------------------------
# Phoenix endpoint
# ------------------------------------------------------------

config :itsm_backend, ItsmBackendWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: 4002
  ],
  secret_key_base: "k/y6Z2rEAFkvOsAYbIi4DlMPuBhem8EVaaDOJOUU6u4voUj8gUQ9k2Np4WH1oRrR",
  server: false

# ------------------------------------------------------------
# Test SurrealDB
#
# Current persistence tests exercise the local development
# SurrealDB service. RuntimeConfig still owns validation.
# ------------------------------------------------------------

config :itsm_backend,
       :surrealdb,
       url: "http://127.0.0.1:8001",
       namespace: "itsm",
       database: "itsm",
       username: "itsm_app",
       password: "itsm_dev_2026"

# ------------------------------------------------------------
# Mailer
# ------------------------------------------------------------

config :itsm_backend,
       ItsmBackend.Mailer,
       adapter: Swoosh.Adapters.Test

config :swoosh,
       :api_client,
       false

# ------------------------------------------------------------
# Test runtime
# ------------------------------------------------------------

config :logger,
  level: :warning

config :phoenix,
       :plug_init_mode,
       :runtime

config :phoenix,
  sort_verified_routes_query_params: true
