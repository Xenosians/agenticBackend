defmodule ItsmBackendWeb.HealthController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.RuntimeConfig

  # ------------------------------------------------------------
  # Public system health
  #
  # Phoenix remains the browser-facing boundary.
  #
  # This endpoint reports:
  # - Phoenix liveness
  # - AI process reachability
  # - AI runtime readiness
  #
  # AI failures do NOT make the Phoenix health endpoint itself
  # fail. They are represented as degraded downstream state.
  # ------------------------------------------------------------

  def index(
        conn,
        _params
      ) do
    ai_client =
      RuntimeConfig.ai_client!()

    ai_health =
      resolve_ai_health(
        ai_client
      )

    ai_readiness =
      resolve_ai_readiness(
        ai_client
      )

    json(
      conn,
      %{
        status:
          "ok",

        service:
          "itsm_backend",

        ai_service: %{
          reachable:
            ai_health.reachable,

          healthy:
            ai_health.healthy,

          ready:
            ai_readiness.ready
        }
      }
    )
  end

  # ------------------------------------------------------------
  # AI health
  # ------------------------------------------------------------

  defp resolve_ai_health(
         ai_client
       ) do
    case ai_client.health() do
      {:ok, _body} ->
        %{
          reachable: true,
          healthy: true
        }

      {:error, _reason} ->
        %{
          reachable: false,
          healthy: false
        }
    end
  rescue
    _error ->
      %{
        reachable: false,
        healthy: false
      }
  end

  # ------------------------------------------------------------
  # AI readiness
  # ------------------------------------------------------------

  defp resolve_ai_readiness(
         ai_client
       ) do
    case ai_client.ready() do
      {:ok, _body} ->
        %{
          ready: true
        }

      {:error, _reason} ->
        %{
          ready: false
        }
    end
  rescue
    _error ->
      %{
        ready: false
      }
  end
end
