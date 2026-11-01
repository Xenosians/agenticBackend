defmodule ItsmBackend.Jobs.Events do
  @moduledoc "Job invalidations emitted only after a successful persistence operation."

  alias ItsmBackend.Jobs.Job
  require Logger

  @queue_topic "job_queue"

  def topic(job_id), do: "job_updates:" <> job_id

  @doc "Topic the queue worker listens on for work it should start without waiting for its poll."
  def queue_topic, do: @queue_topic

  def publish(%Job{id: job_id}) do
    broadcast(topic(job_id), {:job_persisted, job_id})
  end

  @doc """
  Ask the queue worker to look at the queue now instead of at its next poll.

  Sent when new work is saved and when the in-flight job's completion arrives.
  Never sent for the worker's own claims, requeues or failures, so a rejected
  request is not retried in a tight loop. The poll still finds anything a lost
  message would have announced.
  """
  def wake_queue do
    broadcast(@queue_topic, :job_queue_changed)
  end

  def after_write({:ok, %Job{} = job} = result) do
    publish(job)
    result
  end

  def after_write(result), do: result

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(ItsmBackend.PubSub, topic, message)
  rescue
    ArgumentError ->
      Logger.warning("Job update transport unavailable; persisted state remains authoritative")
      :ok
  catch
    :exit, _reason ->
      Logger.warning("Job update transport unavailable; persisted state remains authoritative")
      :ok
  end
end
