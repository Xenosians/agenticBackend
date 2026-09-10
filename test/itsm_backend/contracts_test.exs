defmodule ItsmBackend.ContractsRuntimeTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.Contracts

  test "registry exposes every canonical v1 contract" do
    assert Contracts.names() == [
             :ai_job_accepted,
             :ai_job_completion,
             :ai_job_completion_ack,
             :ai_job_execute_request,
             :error,
             :job_create_request,
             :job_create_response,
             :job_response,
             :tool_proposal
           ]
  end

  test "validates a known contract" do
    assert :ok =
             Contracts.validate(
               :job_create_request,
               %{
                 "user_id" => "jdoe",
                 "message" => "hello"
               }
             )
  end

  test "rejects invalid payload through the registry" do
    assert {:error, errors} =
             Contracts.validate(
               :job_create_request,
               %{
                 "user_id" => "jdoe"
               }
             )

    assert is_list(errors)
    assert errors != []
  end

  test "returns deterministic error for unknown contract" do
    assert {:error,
            {
              :unknown_contract,
              :does_not_exist
            }} =
             Contracts.validate(
               :does_not_exist,
               %{}
             )
  end

  test "rejects invalid validation input" do
    assert {:error,
            {
              :invalid_contract_validation_request,
              :job_create_request,
              "not-a-map"
            }} =
             Contracts.validate(
               :job_create_request,
               "not-a-map"
             )
  end

  test "valid? provides boolean boundary check" do
    assert Contracts.valid?(
             :ai_job_execute_request,
             %{
               "job_id" => "job-123",
               "attempt" => 1,
               "user_id" => "jdoe",
               "message" => "hello"
             }
           )

    refute Contracts.valid?(
             :ai_job_execute_request,
             %{
               "job_id" => "job-123",
               "attempt" => 0,
               "user_id" => "jdoe",
               "message" => "hello"
             }
           )
  end
end
