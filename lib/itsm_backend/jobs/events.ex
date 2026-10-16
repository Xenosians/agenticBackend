defmodule ItsmBackend.Jobs.Events do
  @moduledoc "Job invalidations emitted only after a successful persistence operation."

  alias ItsmBackend.Jobs.Job
  require Logger

  def topic(job_id), do: "job_updates:" <> job_id

  def publish(%Job{id: job_id}) do
    Phoenix.PubSub.broadcast(ItsmBackend.PubSub, topic(job_id), {:job_persisted, job_id})
  rescue
    ArgumentError ->
      Logger.warning("Job update transport unavailable; persisted state remains authoritative")
      :ok
  catch
    :exit, _reason ->
      Logger.warning("Job update transport unavailable; persisted state remains authoritative")
      :ok
  end

  def after_write({:ok, %Job{} = job} = result) do
    publish(job)
    result
  end

  def after_write(result), do: result
end
