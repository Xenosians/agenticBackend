defmodule ItsmBackend.Jobs do
  @moduledoc """
  Public application API for durable AI jobs.
  """

  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Jobs.SurrealStore

  @spec create(map()) ::
          {:ok, Job.t()}
          | {:error, term()}
  def create(attrs)
      when is_map(attrs) do
    with {:ok, job} <-
           Job.new(attrs),
         {:ok, stored_job} <-
           SurrealStore.create(job) do
      {:ok, stored_job}
    end
  end

  @spec get(String.t()) ::
          {:ok, Job.t()}
          | {:error, term()}
  def get(job_id)
      when is_binary(job_id) do
    SurrealStore.get(job_id)
  end

  @spec update(Job.t()) ::
          {:ok, Job.t()}
          | {:error, term()}
  def update(%Job{} = job) do
    SurrealStore.update(job)
  end

  @spec claim_oldest(pos_integer()) ::
          {:ok, Job.t() | nil}
          | {:error, term()}
  def claim_oldest(lease_seconds \\ 300) do
    SurrealStore.claim_oldest(lease_seconds)
  end
end
