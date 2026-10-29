defmodule ItsmBackend.Learning.PublicContract do
  @moduledoc """
  Validates public Learning receipts before forwarding them.

  The AI registry supplies owned resources; this boundary checks the complete
  supported wire schema and the requested identities. A readiness check is
  `ready` only with no blockers; a run receipt must match the exact checked
  selection and can never claim that serving changed or that it was promoted.
  """

  @id ~r/\A[0-9a-f]{32}\z/
  @digest ~r/\A[0-9a-f]{64}\z/
  @methods %{
    "sft" => %{
      roles: ~w(hub specialist),
      tuning: ~w(full lora qlora),
      entrypoint: "scripts/train_recipe.py"
    },
    "dpo" => %{
      roles: ~w(specialist),
      tuning: ~w(qlora),
      entrypoint: "scripts/train_preferences.py"
    },
    "ppo" => %{roles: ~w(hub), tuning: ~w(qlora), entrypoint: "scripts/train_ppo.py"}
  }
  @later_gates ~w(fixed_evaluation_required separate_promotion_required)
  @run_states ~w(running completed failed interrupted cancelled)
  @run_errors ~w(insufficient_gpu_memory chat_template_unsupported example_too_long cuda_unavailable dataset_admission_failed training_failed trainer_unavailable)
  @max_listed_runs 20

  def valid_catalog?(data) do
    exact?(data, ~w(schema methods models datasets promotion_enabled)) and
      data["schema"] == "learning-catalog.v2" and
      disabled?(data, ~w(promotion_enabled)) and
      is_list(data["methods"]) and Enum.all?(data["methods"], &method?/1) and
      Enum.map(data["methods"], & &1["id"]) == ~w(sft dpo ppo) and
      is_list(data["models"]) and Enum.all?(data["models"], &model?/1) and
      is_list(data["datasets"]) and Enum.all?(data["datasets"], &dataset?/1) and
      unique_ids?(data["models"] ++ data["datasets"])
  end

  def valid_preflight?(data, selection) do
    exact?(
      data,
      ~w(schema status preflight_sha256 method role tuning model dataset entrypoint blockers later_gates model_loaded live_tool_execution promotion_enabled)
    ) and
      is_map(selection) and data["schema"] == "learning-selection-preflight.v2" and
      data["status"] in ~w(ready blocked) and data["later_gates"] == @later_gates and
      disabled?(data, ~w(model_loaded live_tool_execution promotion_enabled)) and
      hex?(data["preflight_sha256"], @digest) and selection_match?(data, selection) and
      pinned_model?(data["model"]) and pinned_dataset?(data["dataset"]) and
      data["model"]["id"] == selection["model_id"] and
      data["dataset"]["id"] == selection["dataset_id"] and
      data["dataset"]["sha256"] == selection["dataset_sha256"] and
      blockers_match?(data)
  end

  def valid_runs?(data) do
    exact?(data, ~w(schema runs)) and data["schema"] == "learning-runs.v1" and
      is_list(data["runs"]) and length(data["runs"]) <= @max_listed_runs and
      Enum.all?(data["runs"], &run?/1) and
      length(data["runs"]) == MapSet.size(MapSet.new(data["runs"], & &1["run_id"]))
  end

  def valid_started_run?(data, request) do
    run?(data) and
      Enum.all?(~w(method role tuning preflight_sha256), &(data[&1] == request[&1])) and
      data["model"]["id"] == request["model_id"] and
      data["dataset"]["id"] == request["dataset_id"] and
      data["dataset"]["sha256"] == request["dataset_sha256"]
  end

  def valid_cancelled_run?(data, run_id), do: run?(data) and data["run_id"] == run_id

  defp run?(row) do
    exact?(
      row,
      ~w(schema run_id state method role tuning model dataset preflight_sha256 progress metrics candidate_sha256 error started_at finished_at serving_changed promotion_enabled)
    ) and
      row["schema"] == "learning-run.v1" and hex?(row["run_id"], @id) and
      row["state"] in @run_states and row["method"] == "sft" and
      row["role"] in ~w(hub specialist) and row["tuning"] in ~w(lora qlora) and
      disabled?(row, ~w(serving_changed promotion_enabled)) and
      hex?(row["preflight_sha256"], @digest) and run_model?(row["model"]) and
      run_dataset?(row["dataset"]) and progress?(row["progress"]) and metrics?(row["metrics"]) and
      text?(row["started_at"], 40) and outcome?(row)
  end

  # Only a completed run has a candidate; only a failed one has an error; only an active one is unfinished.
  defp outcome?(row) do
    finished? = text?(row["finished_at"], 40)

    case row["state"] do
      "running" ->
        is_nil(row["finished_at"]) and is_nil(row["candidate_sha256"]) and is_nil(row["error"])

      "completed" ->
        finished? and hex?(row["candidate_sha256"], @digest) and is_nil(row["error"])

      "failed" ->
        finished? and is_nil(row["candidate_sha256"]) and row["error"] in @run_errors

      _ ->
        finished? and is_nil(row["candidate_sha256"]) and is_nil(row["error"])
    end
  end

  defp run_model?(row) do
    exact?(row, ~w(id backend source_kind)) and hex?(row["id"], @id) and
      row["backend"] in ~w(local uploaded) and row["source_kind"] == "local"
  end

  defp run_dataset?(row) do
    exact?(row, ~w(id sha256 version train_count validation_count)) and hex?(row["id"], @id) and
      hex?(row["sha256"], @digest) and positive?(row["version"]) and
      positive?(row["train_count"]) and positive?(row["validation_count"])
  end

  defp progress?(row) do
    exact?(row, ~w(step max_steps)) and is_integer(row["step"]) and positive?(row["max_steps"]) and
      row["step"] in 0..row["max_steps"]
  end

  defp metrics?(row) do
    exact?(row, ~w(train_loss validation_loss)) and
      Enum.all?(~w(train_loss validation_loss), &loss?(row[&1]))
  end

  defp loss?(nil), do: true
  defp loss?(value), do: is_number(value) and value >= 0

  defp blockers_match?(data) do
    expected = expected_blockers(data["method"], data["tuning"], data["model"]["source_kind"])
    blockers = data["blockers"]

    is_list(blockers) and blockers == Enum.sort(blockers) and
      Enum.all?(blockers, &(&1 in expected or &1 == "local_weights_unavailable")) and
      Enum.all?(expected, &(&1 in blockers)) and
      (data["model"]["source_kind"] == "local" or "local_weights_unavailable" not in blockers) and
      data["status"] == if(blockers == [], do: "ready", else: "blocked")
  end

  defp expected_blockers(method, tuning, source) do
    method_blockers =
      case method do
        "dpo" ->
          ~w(host_dispatch_not_integrated reviewed_preference_partitions_required)

        "ppo" ->
          ~w(evaluated_adapter_checkpoint_required host_dispatch_not_integrated independent_simulator_episodes_required)

        _ ->
          if tuning in ~w(lora qlora), do: [], else: ~w(full_tuning_not_offered)
      end

    outbound = if source == "outbound", do: ~w(outbound_connection_is_inference_only), else: []
    Enum.sort(method_blockers ++ outbound)
  end

  defp selection_match?(data, selection) do
    method = @methods[data["method"]]

    is_map(method) and Enum.all?(~w(method role tuning), &(data[&1] == selection[&1])) and
      data["role"] in method.roles and data["tuning"] in method.tuning and
      data["entrypoint"] == method.entrypoint
  end

  defp method?(row) do
    contract = if is_map(row), do: @methods[row["id"]], else: nil

    is_map(contract) and exact?(row, ~w(id roles tuning entrypoint requires)) and
      row["roles"] == contract.roles and row["tuning"] == contract.tuning and
      row["entrypoint"] == contract.entrypoint and text?(row["requires"], 1000)
  end

  defp model?(row) do
    exact?(row, ~w(id name backend state source_kind training_available)) and
      model_fields?(row) and text?(row["name"], 120) and is_boolean(row["training_available"]) and
      (row["training_available"] == false or
         (row["source_kind"] == "local" and row["state"] == "ready"))
  end

  defp pinned_model?(row) do
    exact?(row, ~w(id backend state source_kind)) and model_fields?(row) and
      row["state"] == "ready"
  end

  defp model_fields?(row) do
    hex?(row["id"], @id) and row["state"] in ~w(ready pending rejected) and
      row["backend"] in ~w(local uploaded http pi opencode) and
      row["source_kind"] ==
        if(row["backend"] in ~w(local uploaded), do: "local", else: "outbound")
  end

  defp dataset?(row) do
    exact?(
      row,
      ~w(id name purpose state sha256 lineage_id version train_count validation_count superseded_by)
    ) and
      row["purpose"] == "training" and row["state"] == "ready" and text?(row["name"], 120) and
      dataset_fields?(row) and (is_nil(row["superseded_by"]) or hex?(row["superseded_by"], @id))
  end

  defp pinned_dataset?(row) do
    exact?(row, ~w(id sha256 lineage_id version train_count validation_count)) and
      dataset_fields?(row)
  end

  defp dataset_fields?(row) do
    hex?(row["id"], @id) and hex?(row["lineage_id"], @id) and hex?(row["sha256"], @digest) and
      positive?(row["version"]) and positive?(row["train_count"]) and
      positive?(row["validation_count"]) and
      row["train_count"] + row["validation_count"] >= 10
  end

  defp exact?(value, keys), do: is_map(value) and MapSet.new(Map.keys(value)) == MapSet.new(keys)
  defp disabled?(value, keys), do: Enum.all?(keys, &(value[&1] === false))
  defp hex?(value, pattern), do: is_binary(value) and Regex.match?(pattern, value)

  defp text?(value, max),
    do: is_binary(value) and String.valid?(value) and String.length(value) in 1..max

  defp positive?(value), do: is_integer(value) and value > 0
  defp unique_ids?(rows), do: length(rows) == MapSet.size(MapSet.new(rows, & &1["id"]))
end
