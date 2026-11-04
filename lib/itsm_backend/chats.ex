defmodule ItsmBackend.Chats do
  @moduledoc """
  Durable authenticated chat threads. Job rows remain the canonical turn
  records, so chat history and execution history cannot diverge.
  """

  alias ItsmBackend.Auth.Authorization
  alias ItsmBackend.Chats.SurrealStore
  alias ItsmBackend.Jobs

  def create(user, attrs \\ %{}) do
    now = now()
    title = normalize_title(Map.get(attrs, "title", Map.get(attrs, :title)))

    chat = %{
      "chat_id" => random_id(),
      "user_id" => user["user_id"],
      "title" => title,
      "title_source" => if(title == "New chat", do: "default", else: "manual"),
      "pinned" => false,
      "created_at" => now,
      "updated_at" => now,
      "archived_at" => nil
    }

    with {:ok, stored} <- SurrealStore.create(chat), do: public_chat(stored)
  end

  def list(user) do
    with {:ok, chats} <- SurrealStore.list_for_user(user["user_id"]),
         {:ok, working} <- SurrealStore.working_chat_ids(user["user_id"]) do
      Enum.reduce_while(chats, {:ok, []}, fn chat, {:ok, acc} ->
        case public_chat(chat) do
          # Lets the sidebar show which chats are still working on a request.
          {:ok, row} ->
            {:cont,
             {:ok, [Map.put(row, "working", MapSet.member?(working, row["chat_id"])) | acc]}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, rows} -> {:ok, Enum.reverse(rows)}
        error -> error
      end
    end
  end

  @doc "Updates only the authenticated owner's active thread presentation settings."
  def update(user, chat_id, attrs) do
    with {:ok, changes} <- validate_changes(attrs),
         {:ok, chat} <- get_authorized(user, chat_id),
         true <- is_nil(chat["archived_at"]) || {:error, :not_found},
         {:ok, stored} <- SurrealStore.update(chat["chat_id"], user["user_id"], changes, now()),
         true <-
           valid_update_receipt?(stored, chat, changes) || {:error, :chat_update_outcome_unknown},
         {:ok, public} <- public_chat(stored) do
      {:ok, public}
    else
      {:error, reason} when reason in [:invalid_chat_update, :not_found, :forbidden] ->
        {:error, reason}

      _ ->
        {:error, :chat_update_outcome_unknown}
    end
  end

  @doc "Derives an untitled thread's label from its first durably saved request."
  def title_from_first_request(user_id, chat_id),
    do: SurrealStore.title_from_first_request(chat_id, user_id)

  @search_query_max 200
  @search_result_limit 50
  # Saved turns read per search; the newest matches win when there are more.
  @search_turn_limit 500

  @doc """
  The owner's active chats whose title or saved request text contains
  `query`, matched case-insensitively as literal text. Newest chats first;
  each result names what matched and, for a message, the matching turn.
  """
  def search(user, query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" ->
        {:error, :search_query_required}

      String.length(query) > @search_query_max ->
        {:error, :search_query_too_long}

      true ->
        needle = String.downcase(query)

        with {:ok, chats} <- list(user),
             {:ok, turns} <-
               SurrealStore.matching_turns(user["user_id"], needle, @search_turn_limit) do
          # Turns arrive newest first, so the first one kept per chat is its latest match.
          latest_turn =
            Enum.reduce(turns, %{}, fn turn, acc ->
              Map.put_new(acc, turn["conversation_id"], turn["message"])
            end)

          results =
            chats
            |> Enum.flat_map(&search_result(&1, needle, latest_turn))
            |> Enum.take(@search_result_limit)

          {:ok, results}
        end
    end
  end

  def search(_user, _query), do: {:error, :search_query_required}

  defp search_result(chat, needle, latest_turn) do
    title = chat["title"] || ""
    base = Map.take(chat, ["chat_id", "title", "pinned", "updated_at"])

    cond do
      String.contains?(String.downcase(title), needle) ->
        [Map.merge(base, %{"matched" => "title", "excerpt" => nil})]

      Map.has_key?(latest_turn, chat["chat_id"]) ->
        [Map.merge(base, %{"matched" => "message", "excerpt" => latest_turn[chat["chat_id"]]})]

      true ->
        []
    end
  end

  def get_authorized(user, chat_id) do
    with {:ok, chat} <- SurrealStore.get(chat_id),
         true <- is_map(chat) || {:error, :not_found},
         true <- Authorization.owns_resource?(user, chat["user_id"]) || {:error, :forbidden} do
      public_chat(chat)
    else
      {:error, _} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def touch(chat_id), do: SurrealStore.touch(chat_id, now())

  def archive(user, chat_id) do
    with {:ok, chat} <- get_authorized(user, chat_id),
         :ok <- ensure_no_unfinished_turn(chat),
         {:ok, archived} <- SurrealStore.archive(chat["chat_id"], now()),
         true <- is_map(archived) || {:error, :not_found} do
      {:ok, archived}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  # Deleting a chat would orphan a turn that is queued, running or waiting for
  # the owner's approval.
  defp ensure_no_unfinished_turn(chat) do
    with {:ok, working} <- SurrealStore.working_chat_ids(chat["user_id"]) do
      if MapSet.member?(working, chat["chat_id"]),
        do: {:error, :chat_has_running_job},
        else: :ok
    end
  end

  def history(user, chat_id, limit \\ 100, version \\ 1) do
    with {:ok, chat} <- get_authorized(user, chat_id),
         {:ok, jobs} <- Jobs.list_by_conversation(chat["user_id"], chat["chat_id"], limit) do
      {:ok, Enum.flat_map(jobs, &job_turns(&1, version))}
    end
  end

  def ai_context(user_id, chat_id, exclude_job_id, max_turns) do
    with {:ok, jobs} <- Jobs.list_by_conversation(user_id, chat_id, max_turns * 2 + 2) do
      turns =
        jobs
        |> Enum.reject(&(&1.id == exclude_job_id))
        |> Enum.flat_map(&ai_context_turns/1)
        |> Enum.take(-max_turns)

      {:ok, turns}
    end
  end

  defp ai_context_turns(job) do
    evidence = prior_result_evidence(job)
    turns = Enum.map(job_turns(job), &Map.take(&1, ["role", "content"]))

    cond do
      is_nil(evidence) ->
        turns

      Enum.any?(turns, &(&1["role"] == "assistant")) ->
        Enum.map(turns, fn turn ->
          if turn["role"] == "assistant",
            do: Map.put(turn, "result_evidence", evidence),
            else: turn
        end)

      true ->
        turns ++
          [
            %{
              "role" => "assistant",
              "content" => "A structured historical result record is attached.",
              "result_evidence" => evidence
            }
          ]
    end
  end

  @max_prior_tool_results 4
  @max_prior_tool_result_bytes 4096

  defp prior_result_evidence(%{result: result} = job) when is_map(result) do
    raw_results = result["results"]

    projected_results =
      if(is_list(raw_results), do: raw_results, else: [])
      |> Enum.map(&project_prior_tool_result/1)
      |> Enum.reject(&is_nil/1)

    approval_execution =
      project_prior_approval_execution(
        result["approval_execution"],
        result["approval_history"],
        job
      )

    if projected_results == [] and is_nil(approval_execution) do
      nil
    else
      bounded_results = Enum.take(projected_results, -@max_prior_tool_results)

      evidence = %{
        "job_id" => job.id,
        "job_status" => job.status,
        "results" => bounded_results,
        "results_truncated" => length(projected_results) > length(bounded_results)
      }

      recorded_at = encode_time(job.completed_at || job.claimed_at || job.created_at)

      evidence =
        if is_binary(recorded_at),
          do: Map.put(evidence, "recorded_at", recorded_at),
          else: evidence

      if is_map(approval_execution) do
        Map.put(evidence, "approval_execution", approval_execution)
      else
        evidence
      end
    end
  end

  defp prior_result_evidence(_job), do: nil

  defp project_prior_tool_result(result) when is_map(result) do
    agent_name = result["agent_name"]
    status = result["status"]

    if is_binary(agent_name) and is_binary(status) do
      result
      |> Map.take([
        "agent_name",
        "status",
        "proposed_tool",
        "outcome_code",
        "tool_result",
        "presentation"
      ])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> bounded_prior_tool_result()
    else
      nil
    end
  end

  defp project_prior_tool_result(_result), do: nil

  defp project_prior_approval_execution(outcome, history, job) when is_map(outcome) do
    execution_status = outcome["execution_status"]
    approval_status = outcome["approval_status"]

    if is_binary(execution_status) and is_binary(approval_status) do
      projected = %{
        "execution_status" => execution_status,
        "approval_status" => approval_status
      }

      tool = prior_approval_tool(outcome, history, job)
      projected = if is_binary(tool), do: Map.put(projected, "tool", tool), else: projected

      projected =
        if is_binary(outcome["protocol_status"]),
          do: Map.put(projected, "protocol_status", outcome["protocol_status"]),
          else: projected

      projected =
        if is_boolean(outcome["replayed"]),
          do: Map.put(projected, "replayed", outcome["replayed"]),
          else: projected

      result_is_successful =
        execution_status == "succeeded" and approval_status == "approved" and
          job.status in ["completed", "waiting_approval"]

      projected =
        if result_is_successful and is_map(outcome["result"]) do
          Map.put(projected, "result", outcome["result"])
        else
          if is_map(outcome["result"]),
            do: Map.put(projected, "details_omitted", true),
            else: projected
        end

      bounded_prior_details(projected, ["result"])
    else
      nil
    end
  end

  defp project_prior_approval_execution(_outcome, _history, _job), do: nil

  defp prior_approval_tool(outcome, history, job) when is_list(history) do
    approval_id = outcome["approval_id"]

    prior_proposal =
      history
      |> Enum.reverse()
      |> Enum.find_value(fn entry ->
        execution = if is_map(entry), do: entry["execution"], else: nil
        proposal = if is_map(entry), do: entry["proposal"], else: nil

        if is_map(execution) and execution["approval_id"] == approval_id and is_map(proposal),
          do: proposal["tool"],
          else: nil
      end)

    prior_proposal || current_proposed_tool(job)
  end

  defp prior_approval_tool(_outcome, _history, job), do: current_proposed_tool(job)

  defp current_proposed_tool(%{proposed_tool: %{"tool" => tool}}) when is_binary(tool), do: tool
  defp current_proposed_tool(_job), do: nil

  defp bounded_prior_tool_result(result) do
    bounded_prior_details(result, ["tool_result", "presentation"])
  end

  defp bounded_prior_details(result, detail_keys) do
    result = Enum.reduce(detail_keys, result, &maybe_keep_map(&2, &1))

    case Jason.encode(result) do
      {:ok, encoded} when byte_size(encoded) <= @max_prior_tool_result_bytes ->
        result

      _ ->
        result = Enum.reduce(detail_keys, result, &Map.delete(&2, &1))
        Map.put(result, "details_omitted", true)
    end
  end

  defp maybe_keep_map(result, key) do
    case Map.fetch(result, key) do
      {:ok, value} when is_map(value) -> result
      {:ok, _value} -> Map.delete(result, key)
      :error -> result
    end
  end

  defp job_turns(job, version \\ 1) do
    user_turn = %{
      "role" => "user",
      "content" => job.message,
      "workflow_contract" => job.workflow_contract,
      "workflow_contract_hash" => job.workflow_contract_hash,
      "job_id" => job.id,
      "created_at" => encode_time(job.created_at),
      "status" => ItsmBackend.Jobs.Lifecycle.wire_status(job.status, version)
    }

    case assistant_content(job) do
      nil ->
        [user_turn]

      content ->
        [
          user_turn,
          %{
            "role" => "assistant",
            "content" => content,
            "job_id" => job.id,
            "created_at" => encode_time(job.completed_at || job.claimed_at || job.created_at),
            "status" => ItsmBackend.Jobs.Lifecycle.wire_status(job.status, version),
            "proposed_tool" => job.proposed_tool,
            "references" => answer_references(job),
            "skills" => answer_skills(job)
          }
        ]
    end
  end

  @max_answer_references 10
  @citation_keys ~w(locator dataset_id chunk sha256 content_sha256 source license)
  @resource_id ~r/\A[a-f0-9]{32}\z/
  @digest ~r/\A[a-f0-9]{64}\z/

  # Citations of the reference passages the answer's model was given. Only
  # well-formed citations whose locator matches their own identity are kept;
  # passage text is never part of a citation.
  defp answer_references(%{result: %{"references" => references}}) when is_list(references) do
    references
    |> Enum.filter(&valid_citation?/1)
    |> Enum.uniq_by(& &1["locator"])
    |> Enum.take(@max_answer_references)
  end

  defp answer_references(_job), do: []

  defp valid_citation?(
         %{
           "locator" => locator,
           "dataset_id" => dataset,
           "chunk" => chunk,
           "sha256" => version,
           "content_sha256" => content,
           "source" => source,
           "license" => license
         } = citation
       )
       when map_size(citation) == length(@citation_keys) and is_integer(chunk) and chunk > 0 and
              is_binary(dataset) and is_binary(version) and is_binary(content) and
              is_binary(source) and is_binary(license) do
    Regex.match?(@resource_id, dataset) and Regex.match?(@digest, version) and
      Regex.match?(@digest, content) and short_text?(source, 500) and short_text?(license, 200) and
      locator == "dataset:#{dataset}#chunk:#{chunk}@#{version}"
  end

  defp valid_citation?(_), do: false

  @max_answer_skills 2
  @skill_keys ~w(name version id sha256)
  @skill_name ~r/\A[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?\z/

  # The owner's skills that guided the answer: identities only, so a reloaded
  # chat can say which skill versions shaped it. Skill text never enters history.
  defp answer_skills(%{result: %{"skills" => skills}}) when is_list(skills) do
    skills
    |> Enum.filter(&valid_skill?/1)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.take(@max_answer_skills)
  end

  defp answer_skills(_job), do: []

  defp valid_skill?(
         %{"name" => name, "version" => version, "id" => id, "sha256" => digest} = skill
       )
       when map_size(skill) == length(@skill_keys) and is_binary(name) and is_integer(version) and
              version > 0 and is_binary(id) and is_binary(digest) do
    Regex.match?(@skill_name, name) and Regex.match?(@resource_id, id) and
      Regex.match?(@digest, digest)
  end

  defp valid_skill?(_), do: false

  defp short_text?(value, limit), do: value != "" and String.length(value) <= limit

  defp assistant_content(%{status: status, error: error})
       when status in [
              "failed",
              "denied",
              "outcome_unknown",
              "reconciliation_required",
              "cancelled"
            ] and
              is_binary(error),
       do: error

  defp assistant_content(%{result: result}) when is_map(result) do
    Map.get(result, "answer") || Map.get(result, :answer)
  end

  defp assistant_content(_), do: nil

  defp normalize_title(nil), do: "New chat"

  defp normalize_title(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: "New chat", else: String.slice(value, 0, 160)
  end

  defp normalize_title(_), do: "New chat"

  defp validate_changes(attrs) when is_map(attrs) and map_size(attrs) > 0 do
    valid? =
      Enum.all?(attrs, fn
        {"title", title} when is_binary(title) ->
          String.trim(title) != "" and String.length(String.trim(title)) <= 160

        {"pinned", pinned} when is_boolean(pinned) ->
          true

        _ ->
          false
      end)

    if valid? do
      {:ok,
       Map.new(attrs, fn
         {"title", title} -> {"title", String.trim(title)}
         other -> other
       end)}
    else
      {:error, :invalid_chat_update}
    end
  end

  defp validate_changes(_), do: {:error, :invalid_chat_update}

  defp valid_update_receipt?(stored, previous, changes) do
    stored["chat_id"] == previous["chat_id"] and
      stored["user_id"] == previous["user_id"] and is_nil(stored["archived_at"]) and
      Enum.all?(changes, fn {key, value} -> stored[key] == value end)
  end

  # Old threads predate pinning. Only an absent field receives the compatible default.
  defp public_chat(chat) when is_map(chat) do
    case Map.fetch(chat, "pinned") do
      :error -> {:ok, Map.put(chat, "pinned", false)}
      {:ok, value} when is_boolean(value) -> {:ok, chat}
      _ -> {:error, :invalid_chat_record}
    end
  end

  defp public_chat(_), do: {:error, :invalid_chat_record}

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  defp encode_time(nil), do: nil
  defp encode_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_time(value), do: value
end
