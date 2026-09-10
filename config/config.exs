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

# Environment-specific configuration must remain last.
import_config "#{config_env()}.exs"
