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
    get "/v1/extensions", ExtensionController, :index
    post "/v1/extensions", ExtensionController, :command
    get "/v1/integrations", IntegrationController, :index
    post "/v1/auth/logout", AuthController, :logout
    post "/v1/auth/forgot-password", AuthController, :forgot_password
    post "/v1/auth/reset-password", AuthController, :reset_password
    get "/v1/auth/sessions", SessionController, :index
    post "/v1/auth/sessions/revoke-others", SessionController, :revoke_others
    post "/v1/auth/sessions/:id/revoke", SessionController, :revoke
    get "/v1/auth/preferences", PreferenceController, :show
    put "/v1/auth/preferences", PreferenceController, :update

    # Durable user-owned chat threads.
    post "/v1/chats", ChatController, :create
    get "/v1/chats", ChatController, :index
    # Before /v1/chats/:id, so "search" is never read as a chat id.
    get "/v1/chats/search", ChatController, :search
    get "/v1/chats/:id", ChatController, :show
    get "/v1/chats/:id/history", ChatController, :history
    delete "/v1/chats/:id", ChatController, :delete

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

    post "/v1/jobs/:id/reject", JobController, :reject

    post "/v1/jobs/:id/feedback", JobFeedbackController, :create
    get "/v1/feedback", JobFeedbackController, :index
    get "/v1/feedback/review", FeedbackReviewController, :index
    post "/v1/feedback/:id/review", FeedbackReviewController, :review

    get "/v1/operations", OperationsController, :index

    get "/v2/chats/:id/history", ChatController, :history
    get "/v2/jobs/:id", JobController, :show
    post "/v2/jobs/socket-token", SocketTokenController, :create
    post "/v2/jobs/:id/approve", JobController, :approve
    post "/v2/jobs/:id/reject", JobController, :reject

    # ----------------------------------------------------------
    # Internal AI -> Phoenix durable-job protocol
    # ----------------------------------------------------------

    # Internal trusted account provisioning -> encrypted SurrealDB storage.
    post "/internal/v1/provisioned-accounts",
         ProvisionedAccountController,
         :create

    post "/internal/v1/provisioned-mailboxes", ProvisionedMailboxController, :create

    # Approved AI notification -> durable mail outbox (queued, not delivered).
    post "/internal/v1/notifications", UserNotificationController, :create

    # Approved password reset -> encrypted temporary credential.
    post "/internal/v1/directory-credentials", DirectoryCredentialController, :create

    post "/internal/v1/jobs/:id/heartbeat",
         JobHeartbeatController,
         :heartbeat

    post "/internal/v1/jobs/:id/metrics", JobMetricController, :create

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
