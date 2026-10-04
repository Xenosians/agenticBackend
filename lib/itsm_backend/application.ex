defmodule ItsmBackend.Application do
  @moduledoc false

  use Application

  alias ItsmBackend.RuntimeConfig

  @impl true
  def start(
        _type,
        _args
      ) do
    children =
      [
        ItsmBackendWeb.Telemetry,
        {
          DNSCluster,
          query: RuntimeConfig.dns_cluster_query!()
        },
        {
          Phoenix.PubSub,
          name: ItsmBackend.PubSub
        }
      ] ++
        queue_worker_children() ++
        mail_outbox_worker_children() ++
        [
          ItsmBackendWeb.Endpoint
        ]

    opts = [
      strategy: :one_for_one,
      name: ItsmBackend.Supervisor
    ]

    Supervisor.start_link(
      children,
      opts
    )
  end

  # ------------------------------------------------------------
  # Queue worker
  # ------------------------------------------------------------

  defp queue_worker_children do
    config =
      RuntimeConfig.queue_worker!()

    if config.enabled do
      [
        {
          ItsmBackend.Jobs.QueueWorker,
          [
            poll_interval_ms: config.poll_interval_ms,
            lease_seconds: config.lease_seconds
          ]
        }
      ]
    else
      []
    end
  end

  # ------------------------------------------------------------
  # Durable mail outbox worker
  # ------------------------------------------------------------

  defp mail_outbox_worker_children do
    case Application.get_env(
           :itsm_backend,
           :mail_outbox
         ) do
      config when is_list(config) ->
        if Keyword.get(config, :enabled, false) do
          [
            {
              ItsmBackend.Mail.OutboxWorker,
              [
                poll_interval_ms: Keyword.fetch!(config, :poll_interval_ms),
                lease_seconds: Keyword.fetch!(config, :lease_seconds),
                max_attempts: Keyword.fetch!(config, :max_attempts)
              ]
            }
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  @impl true
  def config_change(
        changed,
        _new,
        removed
      ) do
    ItsmBackendWeb.Endpoint.config_change(
      changed,
      removed
    )

    :ok
  end
end
