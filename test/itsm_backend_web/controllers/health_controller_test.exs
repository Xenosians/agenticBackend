defmodule ItsmBackendWeb.HealthControllerTest do
  use ItsmBackendWeb.ConnCase,
    async: false

  # ============================================================
  # Fake AI clients
  # ============================================================

  defmodule ReadyAIClient do
    @behaviour ItsmBackend.AIClient

    @impl true
    def health do
      {:ok,
       %{
         "status" => "ok"
       }}
    end

    @impl true
    def ready do
      {:ok,
       %{
         "status" => "ready"
       }}
    end

    @impl true
    def run(
          _user_id,
          _message
        ) do
      {:error, :not_used}
    end

    @impl true
    def execute_job(
          _job_id,
          _attempt,
          _user_id,
          _message
        ) do
      {:error, :not_used}
    end

    @impl true
    def approve(
          _approval_id
        ) do
      {:error, :not_used}
    end
  end


  defmodule OfflineAIClient do
    @behaviour ItsmBackend.AIClient

    @impl true
    def health do
      {:error, :offline}
    end

    @impl true
    def ready do
      {:error, :offline}
    end

    @impl true
    def run(
          _user_id,
          _message
        ) do
      {:error, :not_used}
    end

    @impl true
    def execute_job(
          _job_id,
          _attempt,
          _user_id,
          _message
        ) do
      {:error, :not_used}
    end

    @impl true
    def approve(
          _approval_id
        ) do
      {:error, :not_used}
    end
  end

  # ============================================================
  # Setup
  # ============================================================

  setup do
    original_ai_client =
      Application.get_env(
        :itsm_backend,
        :ai_client
      )

    on_exit(fn ->
      restore_env(
        :ai_client,
        original_ai_client
      )
    end)

    :ok
  end

  # ============================================================
  # Ready AI
  # ============================================================

  test "reports Phoenix and ready AI state",
       %{conn: conn} do
    Application.put_env(
      :itsm_backend,
      :ai_client,
      ReadyAIClient
    )

    conn =
      get(
        conn,
        ~p"/api/health"
      )

    assert json_response(
             conn,
             200
           ) == %{
             "status" =>
               "ok",

             "service" =>
               "itsm_backend",

             "ai_service" => %{
               "reachable" =>
                 true,

               "healthy" =>
                 true,

               "ready" =>
                 true
             }
           }
  end

  # ============================================================
  # Offline AI
  #
  # Phoenix remains healthy even when the AI dependency is down.
  # ============================================================

  test "reports degraded AI without failing Phoenix health",
       %{conn: conn} do
    Application.put_env(
      :itsm_backend,
      :ai_client,
      OfflineAIClient
    )

    conn =
      get(
        conn,
        ~p"/api/health"
      )

    assert json_response(
             conn,
             200
           ) == %{
             "status" =>
               "ok",

             "service" =>
               "itsm_backend",

             "ai_service" => %{
               "reachable" =>
                 false,

               "healthy" =>
                 false,

               "ready" =>
                 false
             }
           }
  end

  # ============================================================
  # Environment restoration
  # ============================================================

  defp restore_env(
         key,
         nil
       ) do
    Application.delete_env(
      :itsm_backend,
      key
    )
  end

  defp restore_env(
         key,
         value
       ) do
    Application.put_env(
      :itsm_backend,
      key,
      value
    )
  end
end
