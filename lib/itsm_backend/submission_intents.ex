defmodule ItsmBackend.SubmissionIntents do
  @moduledoc """
  Owner-scoped pre-dispatch identities for browser requests.

  This store never executes work. A pending intent survives a lost reservation
  or dispatch reply. Only a read of the original durable operation acknowledges
  acceptance; missing operations remain pending. A predecessor CAS separates an
  intentional new request from a delayed reservation in another browser tab.
  """
  alias ItsmBackend.{Chats, Jobs, RuntimeConfig, Surreal, Workflows}
  alias ItsmBackend.Jobs.{Job, PublicContract}
  alias ItsmBackend.Learning.PublicContract, as: LearningContract

  @table "submission_intent"
  @id ~r/\A[0-9a-f]{32}\z/
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @learning_fields ~w(method role tuning model_id dataset_id dataset_sha256 preflight_sha256)

  def get(user, kind, target) do
    with :ok <- scope(kind, target),
         {:ok, row} <- read(user["user_id"], kind, target),
         :ok <- valid_stored(row, user["user_id"], kind, target) do
      {:ok, public_slot(kind, target, row)}
    end
  end

  def reserve(user, kind, target, request, previous) do
    with :ok <- scope(kind, target),
         true <- is_nil(previous) or (is_binary(previous) and Regex.match?(@id, previous)),
         {:ok, row} <- read(user["user_id"], kind, target),
         :ok <- valid_stored(row, user["user_id"], kind, target) do
      cond do
        is_map(row) and row["state"] == "pending" ->
          if row["previous_id"] == previous and strip_submission(row["request"]) == request,
            do: {:ok, public_slot(kind, target, row)},
            else: {:error, :pending_intent}

        (is_nil(row) and is_nil(previous)) or
            (is_map(row) and row["intent_id"] == previous and
               row["state"] in ~w(acknowledged rejected)) ->
          with {:ok, context} <- validate_request(user, kind, target, request) do
            candidate = new_record(user["user_id"], kind, target, request, previous, context)

            case write_candidate(row, candidate) do
              {:ok, ^candidate} -> {:ok, public_slot(kind, target, candidate)}
              _ -> recover_reservation(user, kind, target, request, previous)
            end
          end

        true ->
          {:error, :intent_conflict}
      end
    else
      false -> {:error, :invalid_intent}
      error -> error
    end
  end

  def acknowledge(user, kind, target, intent_id) do
    with :ok <- scope(kind, target),
         {:ok, row} when is_map(row) <- read(user["user_id"], kind, target),
         :ok <- valid_stored(row, user["user_id"], kind, target),
         true <- row["intent_id"] == intent_id,
         {:ok, receipt} <- accepted_receipt(user, row),
         {:ok, saved} <- mark(row, "acknowledged", receipt),
         :ok <- valid_stored(saved, user["user_id"], kind, target),
         true <- saved["intent_id"] == intent_id and saved["state"] == "acknowledged" do
      {:ok, public_slot(kind, target, saved)}
    else
      {:ok, nil} -> {:error, :intent_conflict}
      false -> {:error, :intent_conflict}
      error -> error
    end
  end

  # Called only by the boundary that just refused this exact request before
  # admission. A client cannot turn a missing or unknown operation into a
  # rejection: a different payload cannot release the original request, and
  # the server confirms from its own records that nothing was admitted.
  def record_rejection(user, kind, target, request, code) do
    with {:ok, row} when is_map(row) <- read(user["user_id"], kind, target),
         :ok <- valid_stored(row, user["user_id"], kind, target),
         true <- row["state"] == "pending" and row["request"] == request,
         true <- not_admitted?(user, row) do
      mark(row, "rejected", %{"error" => code})
    else
      _ -> {:error, :intent_unavailable}
    end
  end

  defp not_admitted?(user, %{"kind" => "chat", "target_id" => chat, "request" => request}) do
    case Job.new(Map.merge(request, %{"user_id" => user["user_id"], "conversation_id" => chat})) do
      {:ok, expected} -> Jobs.get(expected.id) == {:error, :not_found}
      _ -> false
    end
  end

  defp not_admitted?(user, %{"kind" => "workflow", "request" => request}),
    do: Workflows.run_claimed?(user, request["submission_id"]) == {:ok, false}

  # The learning service refuses only before it records a run for the submission.
  defp not_admitted?(_user, %{"kind" => "learning"}), do: true

  defp validate_request(user, "chat", target, request) do
    with true <-
           is_map(request) and Map.keys(request) -- ~w(chat_id message workflow_contract) == [],
         true <- request["chat_id"] == target,
         {:ok, _} <-
           PublicContract.validate_create_request(Map.put(request, "submission_id", uuid())),
         {:ok, _} <- Chats.get_authorized(user, target) do
      {:ok, nil}
    else
      _ -> {:error, :invalid_intent}
    end
  end

  defp validate_request(user, "workflow", target, request) do
    with true <- is_map(request) and Enum.sort(Map.keys(request)) == ~w(message version),
         true <-
           is_binary(request["message"]) and String.trim(request["message"]) != "" and
             byte_size(request["message"]) <= 16_000,
         {:ok, workflow} <- Workflows.get(user, target),
         true <- request["version"] == workflow["version"] do
      {:ok, workflow}
    else
      _ -> {:error, :invalid_intent}
    end
  end

  defp validate_request(_user, "learning", "candidate", request) do
    if is_map(request) and Enum.sort(Map.keys(request)) == Enum.sort(@learning_fields) and
         request["method"] in ~w(sft dpo ppo) and request["role"] in ~w(hub specialist) and
         request["tuning"] in ~w(full lora qlora) and
         Enum.all?(
           ~w(model_id dataset_id),
           &(is_binary(request[&1]) and Regex.match?(@id, request[&1]))
         ) and
         Enum.all?(
           ~w(dataset_sha256 preflight_sha256),
           &(is_binary(request[&1]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, request[&1]))
         ), do: {:ok, nil}, else: {:error, :invalid_intent}
  end

  defp accepted_receipt(user, %{"kind" => "chat"} = row) do
    request = row["request"]

    with {:ok, expected} <-
           Job.new(
             Map.merge(request, %{
               "user_id" => user["user_id"],
               "conversation_id" => row["target_id"]
             })
           ),
         {:ok, job} <- Jobs.get(expected.id),
         true <-
           job.user_id == expected.user_id and job.conversation_id == expected.conversation_id and
             job.message == expected.message and
             job.workflow_contract_hash == expected.workflow_contract_hash,
         {:ok, receipt} <-
           PublicContract.build_create_response(
             job.id,
             job.status,
             request["submission_id"],
             job.workflow_contract,
             job.workflow_contract_hash
           ) do
      {:ok, receipt}
    else
      _ -> {:error, :intent_outcome_unknown}
    end
  end

  defp accepted_receipt(user, %{"kind" => "workflow"} = row) do
    Workflows.resolve_run(user, row["target_id"], row["request"])
  end

  defp accepted_receipt(user, %{"kind" => "learning", "request" => request}) do
    config = RuntimeConfig.ai_service!()

    case Req.post("#{config.base_url}/internal/v1/learning/runs/resolve",
           headers: [{"x-internal-token", RuntimeConfig.internal_job_token!()}],
           json: %{owner: user["user_id"], submission_id: request["submission_id"]},
           retry: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: receipt}} ->
        if LearningContract.valid_started_run?(receipt, request),
          do: {:ok, receipt},
          else: {:error, :intent_outcome_unknown}

      _ ->
        {:error, :intent_outcome_unknown}
    end
  end

  defp recover_reservation(user, kind, target, request, previous) do
    with {:ok, row} when is_map(row) <- read(user["user_id"], kind, target),
         :ok <- valid_stored(row, user["user_id"], kind, target),
         true <- row["previous_id"] == previous and strip_submission(row["request"]) == request do
      {:ok, public_slot(kind, target, row)}
    else
      false -> {:error, :intent_conflict}
      _ -> {:error, :intent_unavailable}
    end
  end

  defp new_record(owner, kind, target, request, previous, context) do
    identity = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    request =
      Map.put(request, "submission_id", if(kind == "learning", do: identity, else: uuid()))

    %{
      "user_id" => owner,
      "kind" => kind,
      "target_id" => target,
      "intent_id" => identity,
      "previous_id" => previous,
      "state" => "pending",
      "request" => request,
      "context" => context,
      "request_sha256" => digest(request),
      "receipt" => nil
    }
  end

  defp read(owner, kind, target) do
    with {:ok, results} <-
           Surreal.query("SELECT * FROM ONLY type::record($table, $id);", %{
             "table" => @table,
             "id" => slot_id(owner, kind, target)
           }),
         {:ok, row} <- single(results) do
      {:ok, row && Map.delete(row, "id")}
    else
      _ -> {:error, :intent_unavailable}
    end
  end

  defp write_candidate(nil, row) do
    write("CREATE ONLY type::record($table, $id) CONTENT $row RETURN AFTER;", row)
  end

  defp write_candidate(previous, row) do
    write(
      "UPDATE ONLY type::record($table, $id) CONTENT $row WHERE intent_id = $previous AND state IN ['acknowledged', 'rejected'] RETURN AFTER;",
      row,
      %{"previous" => previous["intent_id"]}
    )
  end

  defp mark(row, state, receipt) do
    saved = %{row | "state" => state, "receipt" => receipt}

    write(
      "UPDATE ONLY type::record($table, $id) CONTENT $row WHERE intent_id = $current AND state = $expected_state RETURN AFTER;",
      saved,
      %{"current" => row["intent_id"], "expected_state" => row["state"]}
    )
  end

  defp write(statement, row, extra \\ %{}) do
    with {:ok, results} <-
           Surreal.query(
             statement,
             Map.merge(
               %{
                 "table" => @table,
                 "id" => slot_id(row["user_id"], row["kind"], row["target_id"]),
                 "row" => row
               },
               extra
             )
           ),
         {:ok, saved} when is_map(saved) <- single(results) do
      {:ok, Map.delete(saved, "id")}
    else
      _ -> {:error, :intent_unavailable}
    end
  end

  defp valid_stored(nil, _, _, _), do: :ok

  defp valid_stored(row, owner, kind, target) do
    if is_map(row) and row["user_id"] == owner and row["kind"] == kind and
         row["target_id"] == target and
         is_binary(row["intent_id"]) and Regex.match?(@id, row["intent_id"]) and
         (is_nil(row["previous_id"]) or
            (is_binary(row["previous_id"]) and Regex.match?(@id, row["previous_id"]))) and
         row["state"] in ~w(pending acknowledged rejected) and is_map(row["request"]) and
         row["request_sha256"] == digest(row["request"]) and
         valid_submission?(kind, row["request"]["submission_id"]) do
      :ok
    else
      {:error, :intent_unavailable}
    end
  end

  defp public_slot(kind, target, row),
    do: %{
      "schema" => "submission-intent-slot.v1",
      "kind" => kind,
      "target_id" => target,
      "intent" => row && Map.drop(row, ["user_id"])
    }

  defp strip_submission(request), do: Map.delete(request, "submission_id")
  defp scope("learning", "candidate"), do: :ok

  defp scope(kind, target) when kind in ~w(chat workflow) and is_binary(target),
    do: if(Regex.match?(@id, target), do: :ok, else: {:error, :invalid_intent})

  defp scope(_, _), do: {:error, :invalid_intent}
  defp valid_submission?("learning", value), do: is_binary(value) and Regex.match?(@id, value)
  defp valid_submission?(_, value), do: is_binary(value) and Regex.match?(@uuid, value)
  defp slot_id(owner, kind, target), do: digest([owner, kind, target])

  defp digest(value),
    do: :crypto.hash(:sha256, Jason.encode!(canonical(value))) |> Base.encode16(case: :lower)

  defp canonical(value) when is_map(value),
    do:
      value
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> {k, canonical(v)} end)
      |> Jason.OrderedObject.new()

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp single([%{"status" => "OK", "result" => row}]) when is_map(row) or is_nil(row),
    do: {:ok, row}

  defp single([%{"status" => "OK", "result" => [row]}]) when is_map(row), do: {:ok, row}
  defp single([%{"status" => "OK", "result" => []}]), do: {:ok, nil}
  defp single(_), do: {:error, :intent_unavailable}

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    Enum.join(
      [
        hex(a, 8),
        hex(b, 4),
        hex(0x4000 + Bitwise.band(c, 0xFFF), 4),
        hex(0x8000 + Bitwise.band(d, 0x3FFF), 4),
        hex(e, 12)
      ],
      "-"
    )
  end

  defp hex(value, size),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(size, "0")
end
