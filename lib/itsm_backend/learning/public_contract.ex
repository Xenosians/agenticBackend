defmodule ItsmBackend.Learning.PublicContract do
  @moduledoc """
  Validates public Learning inspection receipts before forwarding them.

  The AI registry supplies owned resources; this boundary checks the complete
  supported wire schema, the requested identities and disabled execution gates.
  A readiness hash identifies an inspection, never admission to a training run.
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
  @base_blockers ~w(trusted_model_identity_required trusted_training_configuration_required fixed_evaluation_required resource_unknown host_dispatch_not_integrated separate_promotion_required)

  def valid_catalog?(data) do
    exact?(data, ~w(schema methods models datasets execution_enabled promotion_enabled)) and
      data["schema"] == "learning-catalog.v1" and
      disabled?(data, ~w(execution_enabled promotion_enabled)) and
      is_list(data["methods"]) and Enum.all?(data["methods"], &method?/1) and
      Enum.map(data["methods"], & &1["id"]) == ~w(sft dpo ppo) and
      is_list(data["models"]) and Enum.all?(data["models"], &model?/1) and
      is_list(data["datasets"]) and Enum.all?(data["datasets"], &dataset?/1) and
      unique_ids?(data["models"] ++ data["datasets"])
  end

  def valid_preflight?(data, selection) do
    exact?(
      data,
      ~w(schema status preflight_sha256 method role tuning model dataset entrypoint resource_state blockers execution_enabled model_loaded live_tool_execution promotion_enabled)
    ) and
      is_map(selection) and data["schema"] == "learning-selection-preflight.v1" and
      data["status"] == "blocked" and data["resource_state"] == "unknown" and
      disabled?(data, ~w(execution_enabled model_loaded live_tool_execution promotion_enabled)) and
      hex?(data["preflight_sha256"], @digest) and selection_match?(data, selection) and
      pinned_model?(data["model"]) and pinned_dataset?(data["dataset"]) and
      data["model"]["id"] == selection["model_id"] and
      data["dataset"]["id"] == selection["dataset_id"] and
      data["dataset"]["sha256"] == selection["dataset_sha256"] and
      data["blockers"] == expected_blockers(data["method"], data["model"]["source_kind"])
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
      model_fields?(row) and text?(row["name"], 120) and row["training_available"] === false
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

  defp expected_blockers(method, source) do
    method_blockers =
      case method do
        "dpo" -> ~w(reviewed_preference_partitions_required)
        "ppo" -> ~w(evaluated_adapter_checkpoint_required independent_simulator_episodes_required)
        _ -> []
      end

    outbound = if source == "outbound", do: ~w(outbound_connection_is_inference_only), else: []
    Enum.sort(@base_blockers ++ method_blockers ++ outbound)
  end

  defp exact?(value, keys), do: is_map(value) and MapSet.new(Map.keys(value)) == MapSet.new(keys)
  defp disabled?(value, keys), do: Enum.all?(keys, &(value[&1] === false))
  defp hex?(value, pattern), do: is_binary(value) and Regex.match?(pattern, value)

  defp text?(value, max),
    do: is_binary(value) and String.valid?(value) and String.length(value) in 1..max

  defp positive?(value), do: is_integer(value) and value > 0
  defp unique_ids?(rows), do: length(rows) == MapSet.size(MapSet.new(rows, & &1["id"]))
end
