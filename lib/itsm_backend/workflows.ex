defmodule ItsmBackend.Workflows do
  @moduledoc """
  Saved, owner-scoped workflows (SRS 1.9 FR-084).

  A workflow is a named, versioned requested-workflow contract plus the canvas
  layout the editor drew it with. Saving never executes anything. A run is one
  ordinary durable job carrying the exact saved contract, so dependencies,
  approvals, idempotency and restart recovery are the job's own guarantees.
  """

  alias ItsmBackend.Jobs
  alias ItsmBackend.Jobs.{Job, Lifecycle, WorkflowContract}
  alias ItsmBackend.Workflows.SurrealStore

  @name_max 120
  @message_max 4000
  @coordinate_limit 100_000
  @list_limit 200
  @run_history_limit 20
  @identity ~r/\A[0-9a-f]{32}\z/

  @doc "The owner's active workflows, most recently updated first."
  def list(user), do: SurrealStore.list_for_user(user["user_id"], @list_limit)

  @doc "One of the owner's workflows; another owner's is reported as missing."
  def get(user, workflow_id) do
    with true <- Regex.match?(@identity, to_string(workflow_id)) || {:error, :not_found},
         {:ok, workflow} when is_map(workflow) <- SurrealStore.get(workflow_id),
         true <- workflow["user_id"] == user["user_id"] || {:error, :not_found},
         true <- is_nil(workflow["archived_at"]) || {:error, :not_found} do
      {:ok, public(workflow)}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def create(user, params) do
    with {:ok, input} <- validate(params) do
      now = now()

      workflow =
        Map.merge(input, %{
          "workflow_id" => random_id(),
          "user_id" => user["user_id"],
          "version" => 1,
          "created_at" => now,
          "updated_at" => now,
          "archived_at" => nil
        })

      with {:ok, stored} <- SurrealStore.create(workflow), do: {:ok, public(stored)}
    end
  end

  @doc """
  Saves a new version. `base_version` must be the version the editor loaded;
  a concurrent save makes it stale and is reported as a conflict.
  """
  def update(user, workflow_id, params) do
    with {:ok, current} <- get(user, workflow_id),
         base when is_integer(base) <- params["base_version"] || {:error, :invalid_workflow},
         true <- base == current["version"] || {:error, :version_conflict},
         {:ok, input} <- validate(params),
         {:ok, stored} <-
           SurrealStore.update_version(user["user_id"], workflow_id, base, input, now()) do
      {:ok, public(stored)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_workflow}
    end
  end

  def archive(user, workflow_id) do
    with {:ok, _workflow} <- get(user, workflow_id),
         {:ok, _} <- SurrealStore.archive(user["user_id"], workflow_id, now()) do
      :ok
    end
  end

  @doc """
  Starts one run of the exact saved version as a durable job in a new chat.

  The job id derives from the owner and `submission_id`, so a retried run
  returns the original job and a different message under the same identity is
  a conflict. A retry reuses the chat the first attempt recorded.
  """
  def run(user, workflow_id, params) do
    with true <-
           (is_binary(workflow_id) and Regex.match?(@identity, workflow_id)) ||
             {:error, :not_found},
         version when is_integer(version) and version > 0 <-
           params["version"] || {:error, :invalid_run},
         {:ok, message} <- run_message(params["message"]),
         submission when is_binary(submission) <-
           params["submission_id"] || {:error, :invalid_run},
         # Reuse the ordinary job's UUID validation and deterministic identity
         # before allocating either a chat or a run record.
         {:ok, expected_job} <-
           Job.new(%{
             "user_id" => user["user_id"],
             "message" => message,
             "submission_id" => submission
           }),
         {:ok, binding} <-
           run_binding(user, workflow_id, version, submission, message, expected_job.id),
         :ok <-
           validate_binding(
             binding,
             user["user_id"],
             workflow_id,
             version,
             submission,
             message,
             expected_job.id
           ),
         {:ok, job} <-
           create_run_job(%{
             "user_id" => user["user_id"],
             "conversation_id" => binding["chat_id"],
             "message" => message,
             "workflow_contract" => binding["definition"],
             "submission_id" => submission
           }),
         true <- matching_job?(job, binding) || {:error, :run_outcome_unknown},
         :ok <- SurrealStore.record_run_job(binding, job.id) do
      workflow = %{
        "workflow_id" => binding["workflow_id"],
        "version" => binding["workflow_version"],
        "definition" => binding["definition"],
        "definition_sha256" => binding["definition_sha256"]
      }

      {:ok, workflow, job, submission}
    else
      {:error, {:invalid_field, :submission_id}} -> {:error, :invalid_run}
      {:error, _} = error -> error
      _ -> {:error, :invalid_run}
    end
  end

  @doc """
  The runs of one of the owner's workflows with each job's current status.
  A run whose job can no longer be read is listed as `unknown`, never dropped.
  """
  def runs(user, workflow_id) do
    owner = user["user_id"]

    with {:ok, _workflow} <- get(user, workflow_id),
         {:ok, rows} <- SurrealStore.list_runs(owner, workflow_id, @run_history_limit) do
      {:ok,
       Enum.map(rows, fn row ->
         status =
           case if(is_binary(row["job_id"]),
                  do: Jobs.get(row["job_id"]),
                  else: {:error, :missing_job}
                ) do
             {:ok, %{user_id: ^owner} = job} ->
               if row["binding_version"] === 1 and
                    row["request_sha256"] == SurrealStore.binding_digest(row) and
                    is_map(row["definition"]) and
                    WorkflowContract.validate_binding(row["definition"], row["definition_sha256"]) ==
                      :ok and
                    matching_job?(job, row),
                  do: Lifecycle.wire_status(job.status, 2),
                  else: "unknown"

             _ ->
               "unknown"
           end

         row
         |> Map.take(~w(job_id chat_id workflow_id workflow_version definition_sha256 created_at))
         |> Map.put("status", status)
       end)}
    end
  end

  # Recover an admitted operation before consulting mutable workflow state.
  # Editing or archiving a workflow must not prevent reconciliation of its
  # original submission, nor relabel that submission as the current version.
  defp run_binding(user, workflow_id, version, submission, message, job_id) do
    case SurrealStore.get_run(user["user_id"], submission) do
      {:ok, binding} when is_map(binding) ->
        {:ok, binding}

      {:ok, nil} ->
        with {:ok, workflow} <- get(user, workflow_id),
             true <- version == workflow["version"] || {:error, :version_conflict} do
          SurrealStore.claim_run(user["user_id"], submission, workflow, message, job_id)
        end

      _ ->
        {:error, :run_outcome_unknown}
    end
  end

  defp validate_binding(binding, owner, workflow_id, version, submission, message, job_id) do
    valid? =
      binding["binding_version"] === 1 and binding["user_id"] == owner and
        binding["submission_id"] == submission and binding["expected_job_id"] == job_id and
        is_binary(binding["expected_job_id"]) and
        Regex.match?(@identity, binding["expected_job_id"]) and
        is_binary(binding["workflow_id"]) and Regex.match?(@identity, binding["workflow_id"]) and
        is_integer(binding["workflow_version"]) and binding["workflow_version"] > 0 and
        is_binary(binding["chat_id"]) and Regex.match?(@identity, binding["chat_id"]) and
        is_binary(binding["message"]) and binding["message"] != "" and
        binding["job_id"] in [nil, job_id] and
        WorkflowContract.validate_binding(binding["definition"], binding["definition_sha256"]) ==
          :ok and
        is_map(binding["definition"]) and
        binding["request_sha256"] == SurrealStore.binding_digest(binding)

    cond do
      not valid? ->
        {:error, :run_outcome_unknown}

      binding["workflow_id"] != workflow_id or binding["workflow_version"] != version or
          binding["message"] != message ->
        {:error, :submission_conflict}

      true ->
        :ok
    end
  end

  defp create_run_job(attrs) do
    case Jobs.create(attrs) do
      {:ok, job} -> {:ok, job}
      {:error, :submission_conflict} = error -> error
      _ -> {:error, :run_outcome_unknown}
    end
  end

  defp matching_job?(job, binding) do
    job.id == binding["expected_job_id"] and job.user_id == binding["user_id"] and
      job.conversation_id == binding["chat_id"] and job.message == binding["message"] and
      job.workflow_contract == binding["definition"] and
      job.workflow_contract_hash == binding["definition_sha256"]
  end

  defp validate(params) when is_map(params) do
    with {:ok, name} <- name(params["name"]),
         {:ok, definition, digest} <- definition(params["definition"]),
         {:ok, layout} <- layout(params["layout"], definition) do
      {:ok,
       %{
         "name" => name,
         "definition" => definition,
         "definition_sha256" => digest,
         "layout" => layout
       }}
    end
  end

  defp validate(_), do: {:error, :invalid_workflow}

  defp name(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and String.length(value) <= @name_max,
      do: {:ok, value},
      else: {:error, :invalid_workflow}
  end

  defp name(_), do: {:error, :invalid_workflow}

  defp definition(value) when is_map(value) do
    case WorkflowContract.validate(value) do
      {:ok, definition, digest} when is_map(definition) -> {:ok, definition, digest}
      _ -> {:error, :invalid_workflow}
    end
  end

  defp definition(_), do: {:error, :invalid_workflow}

  # Every step has exactly one finite position; geometry never becomes an argument.
  defp layout(value, %{"steps" => steps}) when is_map(value) do
    ids = MapSet.new(steps, & &1["id"])

    valid? =
      MapSet.new(Map.keys(value)) == ids and
        Enum.all?(value, fn
          {_id, %{"x" => x, "y" => y} = position} when map_size(position) == 2 ->
            coordinate?(x) and coordinate?(y)

          _ ->
            false
        end)

    if valid?, do: {:ok, value}, else: {:error, :invalid_workflow}
  end

  defp layout(_, _), do: {:error, :invalid_workflow}

  defp coordinate?(value) when is_integer(value), do: abs(value) <= @coordinate_limit
  defp coordinate?(_), do: false

  defp run_message(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and String.length(value) <= @message_max,
      do: {:ok, value},
      else: {:error, :invalid_run}
  end

  defp run_message(_), do: {:error, :invalid_run}

  defp public(workflow) do
    workflow
    |> Map.take(
      ~w(workflow_id name version definition definition_sha256 layout created_at updated_at)
    )
    |> Map.put("execution", "durable_job")
  end

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
end
