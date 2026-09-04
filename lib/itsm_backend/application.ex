defmodule ItsmBackend.Application do
  @moduledoc false

  use Application

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
          query:
            Application.get_env(
              :itsm_backend,
              :dns_cluster_query
            ) || :ignore
        },
        {
          Phoenix.PubSub,
          name: ItsmBackend.PubSub
        }
      ] ++
        queue_worker_children() ++
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

  defp queue_worker_children do
    config =
      Application.get_env(
        :itsm_backend,
        :queue_worker,
        []
      )

    if Keyword.get(
         config,
         :enabled,
         false
       ) do
      [
        {
          ItsmBackend.Jobs.QueueWorker,
          [
            poll_interval_ms:
              Keyword.get(
                config,
                :poll_interval_ms,
                1_000
              ),
            lease_seconds:
              Keyword.get(
                config,
                :lease_seconds,
                300
              )
          ]
        }
      ]
    else
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
