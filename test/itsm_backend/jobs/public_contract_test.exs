defmodule ItsmBackend.Jobs.PublicContractTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.Jobs.PublicContract

  # ------------------------------------------------------------
  # Create request
  # ------------------------------------------------------------

  test "accepts create request without conversation id" do
    payload = %{
      "user_id" => "jdoe",
      "message" => "Check my account."
    }

    assert {:ok, ^payload} =
             PublicContract.validate_create_request(payload)
  end

  test "accepts create request with conversation id" do
    payload = %{
      "user_id" => "jdoe",
      "conversation_id" => "conversation-123",
      "message" => "Continue this conversation."
    }

    assert {:ok, ^payload} =
             PublicContract.validate_create_request(payload)
  end

  test "rejects explicitly blank conversation id" do
    assert {:error,
            {
              :invalid_job_create_request,
              :contract_violation,
              errors
            }} =
             PublicContract.validate_create_request(%{
               "user_id" => "jdoe",
               "conversation_id" => "",
               "message" => "hello"
             })

    assert is_list(errors)
    assert errors != []
  end

  test "rejects unknown create request fields" do
    assert {:error,
            {
              :invalid_job_create_request,
              :contract_violation,
              errors
            }} =
             PublicContract.validate_create_request(%{
               "user_id" => "jdoe",
               "message" => "hello",
               "debug" => true
             })

    assert is_list(errors)
    assert errors != []
  end

  test "rejects non-map create request" do
    assert {:error,
            {
              :invalid_job_create_request,
              :invalid_payload_type,
              "invalid"
            }} =
             PublicContract.validate_create_request("invalid")
  end

  # ------------------------------------------------------------
  # Create response
  # ------------------------------------------------------------

  test "builds canonical pending create response" do
    assert {:ok,
            %{
              "job_id" => "job-123",
              "status" => "pending"
            }} =
             PublicContract.build_create_response(
               "job-123",
               "pending"
             )
  end

  test "rejects non-pending initial response state" do
    assert {:error,
            {
              :invalid_job_create_response,
              :contract_violation,
              errors
            }} =
             PublicContract.build_create_response(
               "job-123",
               "processing"
             )

    assert is_list(errors)
    assert errors != []
  end

  test "rejects blank create response job id" do
    assert {:error,
            {
              :invalid_job_create_response,
              :contract_violation,
              errors
            }} =
             PublicContract.build_create_response(
               "",
               "pending"
             )

    assert is_list(errors)
    assert errors != []
  end
end
