defmodule ItsmBackendWeb.Router do
  use ItsmBackendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", ItsmBackendWeb do
    pipe_through :api

    get "/health",
        HealthController,
        :index

    post "/v1/agent/run",
         AgentController,
         :run

    # Transitional direct approval endpoint.
    post "/v1/approvals/:approval_id/approve",
         ApprovalController,
         :approve

    post "/v1/jobs",
         JobController,
         :create

    get "/v1/jobs/:id",
        JobController,
        :show

    post "/v1/jobs/:id/approve",
         JobController,
         :approve

    post "/internal/v1/jobs/:id/completion",
         JobCompletionController,
         :complete
  end
end
