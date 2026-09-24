defmodule ItsmBackendWeb.Router do
  use ItsmBackendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api",
        ItsmBackendWeb do
    pipe_through :api

    get "/health",
        HealthController,
        :index

    # Application authentication / identity.
    post "/v1/auth/register", AuthController, :register
    post "/v1/auth/verify-email", AuthController, :verify_email
    post "/v1/auth/resend-verification", AuthController, :resend_verification
    post "/v1/auth/login", AuthController, :login
    get "/v1/auth/me", AuthController, :me
    post "/v1/auth/logout", AuthController, :logout
    post "/v1/auth/forgot-password", AuthController, :forgot_password
    post "/v1/auth/reset-password", AuthController, :reset_password
    get "/v1/auth/sessions", SessionController, :index
    post "/v1/auth/sessions/:id/revoke", SessionController, :revoke

    # Durable user-owned chat threads.
    post "/v1/chats", ChatController, :create
    get "/v1/chats", ChatController, :index
    get "/v1/chats/:id", ChatController, :show
    get "/v1/chats/:id/history", ChatController, :history

    post "/v1/agent/run",
         AgentController,
         :run

    post "/v1/jobs",
         JobController,
         :create

    get "/v1/jobs/:id",
        JobController,
        :show

    post "/v1/jobs/:id/approve",
         JobController,
         :approve

    # ----------------------------------------------------------
    # Internal AI -> Phoenix durable-job protocol
    # ----------------------------------------------------------

    # Internal trusted account provisioning -> encrypted SurrealDB storage.
    post "/internal/v1/provisioned-accounts",
         ProvisionedAccountController,
         :create

    post "/internal/v1/jobs/:id/heartbeat",
         JobHeartbeatController,
         :heartbeat

    post "/internal/v1/jobs/:id/completion",
         JobCompletionController,
         :complete
  end
  if Application.compile_env(:itsm_backend, :dev_routes, false) do
    scope "/dev" do
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

end
