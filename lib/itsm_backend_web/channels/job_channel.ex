defmodule ItsmBackendWeb.JobChannel do
  use ItsmBackendWeb, :channel

  alias ItsmBackend.Auth
  alias ItsmBackend.Auth.Authorization
  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.Events
  alias ItsmBackend.Jobs.Lifecycle
  alias ItsmBackendWeb.JobProgressChannel

  @impl true
  def join("job:" <> job_id, _payload, socket) do
    with true <- Regex.match?(~r/\A[0-9a-f]{32}\z/, job_id),
         {:ok, job} <- authorized_job(socket, job_id) do
      :ok = Phoenix.PubSub.subscribe(ItsmBackend.PubSub, Events.topic(job_id))
      Process.send_after(self(), :check_session, 60_000)
      {:ok, summary(job), assign(socket, :job_id, job_id)}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "read_only"}}, socket}
  end

  @impl true
  def handle_info({:job_persisted, job_id}, %{assigns: %{job_id: job_id}} = socket) do
    case authorized_job(socket, job_id) do
      {:ok, job} ->
        push(socket, "job_updated", summary(job))
        {:noreply, socket}

      _ ->
        {:stop, :normal, socket}
    end
  end

  def handle_info(:check_session, socket) do
    case Auth.authenticate_session_id(socket.assigns.user_id, socket.assigns.session_id) do
      {:ok, _user, _session} ->
        Process.send_after(self(), :check_session, 60_000)
        {:noreply, socket}

      _ ->
        {:stop, :normal, socket}
    end
  end

  def handle_info({:job_progress, job_id, attempt, stage}, %{assigns: %{job_id: job_id}} = socket) do
    with {:ok, _job} <- authorized_job(socket, job_id),
         {:ok, _active_job} <- JobProgressChannel.active_job(job_id, attempt) do
      push(socket, "job_progress", %{job_id: job_id, attempt: attempt, stage: stage})
      {:noreply, socket}
    else
      {:error, :inactive_attempt} -> {:noreply, socket}
      _ -> {:stop, :normal, socket}
    end
  end

  defp authorized_job(socket, job_id) do
    with {:ok, user, _session} <-
           Auth.authenticate_session_id(socket.assigns.user_id, socket.assigns.session_id),
         {:ok, job} <- Jobs.get(job_id),
         true <- Authorization.owns_resource?(user, job.user_id) do
      {:ok, job}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp summary(job) do
    %{job_id: job.id, status: Lifecycle.wire_status(job.status, 2), attempts: job.attempts}
  end
end
