import Config

# ------------------------------------------------------------
# Production HTTPS policy
#
# Public URL and bind configuration are supplied at runtime.
# TLS forwarding remains deterministic production policy.
# ------------------------------------------------------------

config :itsm_backend, ItsmBackendWeb.Endpoint,
  force_ssl: [
    rewrite_on: [
      :x_forwarded_proto
    ]
  ]

# ------------------------------------------------------------
# Mailer
# ------------------------------------------------------------

config :swoosh,
  api_client: Swoosh.ApiClient.Req

config :swoosh,
  local: false

# ------------------------------------------------------------
# Logger
# ------------------------------------------------------------

config :logger,
  level: :info

# Runtime production configuration is loaded by runtime.exs.
