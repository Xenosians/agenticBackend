# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :itsm_backend,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :itsm_backend, ItsmBackendWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ItsmBackendWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ItsmBackend.PubSub,
  live_view: [signing_salt: "Iqpmeovp"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :itsm_backend, ItsmBackend.Mailer, adapter: Swoosh.Adapters.Local

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :itsm_backend,
  ai_client: ItsmBackend.AIClient.HTTP,
  ai_service_url: "http://127.0.0.1:8000"

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :itsm_backend,
       :queue_worker,
       enabled: true,
       poll_interval_ms: 1_000,
       lease_seconds: 300

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

config :itsm_backend,
  ai_client: ItsmBackend.AIClient.HTTP,
  ai_service_url: "http://127.0.0.1:8000"

config :itsm_backend,
       :surrealdb,
       url: "http://127.0.0.1:8001",
       namespace: "itsm",
       database: "itsm",
       username: "itsm_app",
       password: "itsm_dev_2026"

config :itsm_backend,
       :queue_worker,
       enabled: false
