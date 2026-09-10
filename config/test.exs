import Config

# We don't run a server during test.
config :itsm_backend, ItsmBackendWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: 4002
  ],
  secret_key_base: "k/y6Z2rEAFkvOsAYbIi4DlMPuBhem8EVaaDOJOUU6u4voUj8gUQ9k2Np4WH1oRrR",
  server: false

# In test we don't send emails.
config :itsm_backend,
       ItsmBackend.Mailer,
       adapter: Swoosh.Adapters.Test

config :swoosh,
       :api_client,
       false

config :logger,
  level: :warning

config :phoenix,
       :plug_init_mode,
       :runtime

config :phoenix,
  sort_verified_routes_query_params: true
