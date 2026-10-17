defmodule ItsmBackendWeb.JobProgressChannel do
  @moduledoc """
  The AI's channel for one processing attempt: ephemeral progress hints and the
  two-way lease heartbeat. Completion stays on the durable HTTP callback/outbox.
  """
  use ItsmBackendWeb, :channel

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Events
  alias ItsmBackendWeb.LeaseRenewal

  @stages ~w(routing planning executing synthesizing waiting_provider)

  @impl true
  def join("ai_jobs:" <> job_id, %{"attempt" => attempt} = payload, socket)
      when is_integer(attempt) and attempt > 0 and map_size(payload) == 1 do
    with true <- Regex.match?(~r/\A[0-9a-f]{32}\z/, job_id),
         {:ok, _job} <- active_job(job_id, attempt) do
      {:ok, %{job_id: job_id, attempt: attempt}, assign(socket, job_id: job_id, attempt: attempt)}
    else
      _ -> {:error, %{reason: "inactive_attempt"}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "invalid_request"}}

  @impl true
  def handle_in("progress", %{"stage" => stage} = payload, socket)
      when stage in @stages and map_size(payload) == 1 do
    %{job_id: job_id, attempt: attempt} = socket.assigns

    case active_job(job_id, attempt) do
      {:ok, _job} ->
        Phoenix.PubSub.broadcast(
          ItsmBackend.PubSub,
          Events.topic(job_id),
          {:job_progress, job_id, attempt, stage}
        )

        {:reply, {:ok, %{accepted: true}}, socket}

      _ ->
        {:reply, {:error, %{reason: "inactive_attempt"}}, socket}
    end
  end

  # Renews only the joined attempt. The reply is the HTTP heartbeat contract,
  # and the HTTP heartbeat remains the AI's fallback transport.
  def handle_in("renew_lease", payload, socket) when map_size(payload) == 0 do
    %{job_id: job_id, attempt: attempt} = socket.assigns

    case LeaseRenewal.renew(job_id, attempt) do
      {:ok, body} -> {:reply, {:ok, body}, socket}
      {:error, _status, body} -> {:reply, {:error, body}, socket}
    end
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "invalid_request"}}, socket}
  end

  def active_job(job_id, attempt) do
    with {:ok,
          %{status: "processing", attempts: ^attempt, lease_expires_at: %DateTime{} = expiry} =
            job} <-
           Jobs.get(job_id),
         :gt <- DateTime.compare(expiry, DateTime.utc_now()) do
      {:ok, job}
    else
      _ -> {:error, :inactive_attempt}
    end
  end
end
