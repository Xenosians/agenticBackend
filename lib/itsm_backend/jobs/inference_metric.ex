defmodule ItsmBackend.Jobs.InferenceMetric do
  @moduledoc "Content-free observations of an inference call; never execution authority."

  @stages ~w(CONTROL_ROUTING CANDIDATE_NARROWING SEMANTIC_ROUTING SEMANTIC_ROUTING_BROAD SPECIALIST_REASONING PRIMARY_RESPONSE SYNTHESIS REPAIR NETWORKING NETWORKING_SELECTED INVALID)
  @required ~w(attempt event_id stage operation adapter outcome duration_ms)
  @timings ~w(queue_ms execution_ms first_token_ms)
  @integers ~w(generated_tokens estimated_input_tokens request_token_budget output_token_cap dropped_messages)
  @optional ~w(role repair_of) ++ @timings ++ @integers
  @fields @required ++ @optional
  @identity ~r/\A[0-9a-f]{32}\z/
  @role ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  def fields, do: @fields
  def required_fields, do: @required
  def optional_fields, do: @optional

  def valid_id?(value), do: is_binary(value) and Regex.match?(@identity, value)

  def validate(input) when is_map(input) do
    with true <- Enum.all?(@required, &Map.has_key?(input, &1)),
         true <- Enum.all?(Map.keys(input), &(&1 in @fields)),
         true <- is_integer(input["attempt"]) and input["attempt"] > 0,
         true <- valid_id?(input["event_id"]),
         true <- input["stage"] in @stages,
         true <- input["operation"] in ~w(warm generate),
         true <- input["adapter"] in ~w(local http pi opencode hf-causal unresolved),
         true <- input["outcome"] in ~w(success error cancelled budget_rejected skipped),
         true <- timing?(input["duration_ms"]),
         true <-
           is_nil(input["role"]) or
             (is_binary(input["role"]) and Regex.match?(@role, input["role"])),
         true <- is_nil(input["repair_of"]) or input["repair_of"] in @stages,
         true <- Enum.all?(@timings, &(is_nil(input[&1]) or timing?(input[&1]))),
         true <- Enum.all?(@integers, &(is_nil(input[&1]) or integer?(input[&1]))) do
      {:ok, Map.new(@fields, &{&1, Map.get(input, &1)})}
    else
      _ -> {:error, :invalid_metric}
    end
  end

  def validate(_input), do: {:error, :invalid_metric}

  defp timing?(value), do: is_number(value) and value >= 0 and value <= 86_400_000
  defp integer?(value), do: is_integer(value) and value >= 0 and value <= 1_000_000_000
end
