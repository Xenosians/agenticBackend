import Config

# ------------------------------------------------------------
# Application
# ------------------------------------------------------------

config :itsm_backend,
  generators: [
    timestamp_type: :utc_datetime
  ],
  ai_client: ItsmBackend.AIClient.HTTP

# ------------------------------------------------------------
# Phoenix endpoint
# ------------------------------------------------------------

config :itsm_backend, ItsmBackendWeb.Endpoint,
  url: [
    host: "localhost"
  ],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [
      json: ItsmBackendWeb.ErrorJSON
    ],
    layout: false
  ],
  pubsub_server: ItsmBackend.PubSub,
  live_view: [
    signing_salt: "Iqpmeovp"
  ]

# ------------------------------------------------------------
# Mailer
# ------------------------------------------------------------

config :itsm_backend,
       ItsmBackend.Mailer,
       adapter: Swoosh.Adapters.Local

# ------------------------------------------------------------
# Logger
# ------------------------------------------------------------

config :logger,
       :default_formatter,
       format: "$time $metadata[$level] $message\n",
       metadata: [
         :request_id
       ]

# ------------------------------------------------------------
# JSON
# ------------------------------------------------------------

config :phoenix,
       :json_library,
       Jason

# ------------------------------------------------------------
# Internal service authentication
#
# Transitional until the dedicated secret configuration slice.
# ------------------------------------------------------------

config :itsm_backend,
  internal_job_token:
    System.get_env(
      "ITSM_INTERNAL_JOB_TOKEN",
      "itsm-dev-internal-2026"
    )

# ------------------------------------------------------------
# SurrealDB
#
# Transitional until the database configuration slice.
# ------------------------------------------------------------

config :itsm_backend,
       :surrealdb,
       url: "http://127.0.0.1:8001",
       namespace: "itsm",
       database: "itsm",
       username: "itsm_app",
       password: "itsm_dev_2026"

import_config "#{config_env()}.exs"
