defmodule ItsmBackendWeb.Endpoint do
  use Phoenix.Endpoint,
    otp_app: :itsm_backend

  @session_options [
    store: :cookie,
    key: "_itsm_backend_key",
    signing_salt: "Qt8cTnFh",
    same_site: "Lax"
  ]

  socket "/live",
         Phoenix.LiveView.Socket,
         websocket: [
           connect_info: [
             session: @session_options
           ]
         ],
         longpoll: [
           connect_info: [
             session: @session_options
           ]
         ]

  plug Plug.Static,
    at: "/",
    from: :itsm_backend,
    gzip: not code_reloading?,
    only: ItsmBackendWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId

  plug Plug.Telemetry,
    event_prefix: [
      :phoenix,
      :endpoint
    ]

  # ------------------------------------------------------------
  # Browser frontend boundary
  #
  # Development frontend:
  #   http://localhost:8080
  #   http://127.0.0.1:8080
  #
  # Keep this explicit rather than allowing "*".
  # ------------------------------------------------------------

  plug CORSPlug,
    origin: [
      "http://localhost:8080",
      "http://127.0.0.1:8080"
    ],
    methods: [
      "GET",
      "POST",
      "OPTIONS"
    ],
    headers: [
      "content-type"
    ]

  plug Plug.Parsers,
    parsers: [
      :urlencoded,
      :multipart,
      :json
    ],
    pass: [
      "*/*"
    ],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head

  plug Plug.Session,
       @session_options

  plug ItsmBackendWeb.Router
end
