defmodule ItsmBackend.Jobs.WorkflowContract do
  @moduledoc """
  Validates a user's explicit requested operations and their dependency order.

  A contract restricts plan completeness. It grants no tool permission or approval.
  Its stable digest preserves targets exactly and is computed by Phoenix.
  """

  @contract_keys MapSet.new(["version", "steps"])
  @step_keys MapSet.new(["id", "capability", "grounded_arguments", "after_success_of"])
  @id ~r/\A[A-Za-z][A-Za-z0-9_-]{0,79}\z/
  @capability ~r/\A[A-Za-z0-9_.-]{1,150}\z/
  @argument ~r/\A[A-Za-z_][A-Za-z0-9_]{0,149}\z/

  @spec validate(term()) :: {:ok, map() | nil, String.t() | nil} | {:error, term()}
  def validate(nil), do: {:ok, nil, nil}

  def validate(%{"version" => version, "steps" => steps} = contract)
      when version === 1 and is_list(steps) and length(steps) in 1..8 do
    with true <- MapSet.new(Map.keys(contract)) == @contract_keys,
         :ok <- validate_steps(steps),
         {:ok, encoded} <- Jason.encode(contract),
         true <- byte_size(encoded) <= 32_768 do
      {:ok, contract, digest(contract)}
    else
      _ -> invalid()
    end
  end

  def validate(_), do: invalid()

  @spec validate_binding(term(), term()) :: :ok | {:error, term()}
  def validate_binding(contract, hash) do
    case validate(contract) do
      {:ok, _, ^hash} -> :ok
      _ -> invalid()
    end
  end

  defp validate_steps(steps) do
    Enum.reduce_while(steps, {:ok, MapSet.new(), MapSet.new()}, fn step, {:ok, ids, tools} ->
      case step do
        %{
          "id" => id,
          "capability" => capability,
          "grounded_arguments" => arguments,
          "after_success_of" => dependency
        }
        when is_binary(id) and is_binary(capability) and is_map(arguments) ->
          valid? =
            MapSet.new(Map.keys(step)) == @step_keys and Regex.match?(@id, id) and
              Regex.match?(@capability, capability) and not MapSet.member?(ids, id) and
              not MapSet.member?(tools, capability) and valid_arguments?(arguments) and
              (is_nil(dependency) or MapSet.member?(ids, dependency))

          if valid?,
            do: {:cont, {:ok, MapSet.put(ids, id), MapSet.put(tools, capability)}},
            else: {:halt, invalid()}

        _ ->
          {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, _, _} -> :ok
      error -> error
    end
  end

  defp valid_arguments?(arguments) do
    map_size(arguments) <= 32 and
      Enum.all?(arguments, fn
        {key, values} when is_binary(key) and is_list(values) and length(values) in 1..16 ->
          Regex.match?(@argument, key) and
            Enum.all?(values, fn value ->
              is_binary(value) and String.valid?(value) and value != "" and
                length(String.codepoints(value)) <= 1024
            end)

        _ ->
          false
      end)
  end

  defp digest(%{"steps" => steps}) do
    projection =
      Enum.map(steps, fn step ->
        arguments =
          step["grounded_arguments"]
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {key, values} -> [key, values] end)

        [step["id"], step["capability"], arguments, step["after_success_of"]]
      end)

    :crypto.hash(:sha256, Jason.encode!(["itsm-requested-workflow.v1", 1, projection]))
    |> Base.encode16(case: :lower)
  end

  defp invalid, do: {:error, {:invalid_field, :workflow_contract}}
end
