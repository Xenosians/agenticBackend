defmodule ItsmBackend.AIClient.JobContractTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.AIClient.JobContract

  # ------------------------------------------------------------
  # Execute request
  # ------------------------------------------------------------

  test "builds a contract-valid execution request" do
    assert {:ok,
            %{
              "job_id" => "job-123",
              "attempt" => 1,
              "user_id" => "jdoe",
              "message" => "Check account."
            }} =
             JobContract.build_execute_request(
               "job-123",
               1,
               "jdoe",
               "Check account."
             )
  end

  test "rejects an invalid execution attempt before transport" do
    assert {:error,
            {
              :invalid_ai_job_execute_request,
              errors
            }} =
             JobContract.build_execute_request(
               "job-123",
               0,
               "jdoe",
               "Check account."
             )

    assert is_list(errors)
    assert errors != []
  end

  test "rejects blank execution identifiers before transport" do
    assert {:error,
            {
              :invalid_ai_job_execute_request,
              errors
            }} =
             JobContract.build_execute_request(
               "",
               1,
               "jdoe",
               "Check account."
             )

    assert is_list(errors)
    assert errors != []
  end

  # ------------------------------------------------------------
  # Execution acknowledgement
  # ------------------------------------------------------------

  test "accepts a correlated AI acknowledgement" do
    body = %{
      "job_id" => "job-123",
      "attempt" => 1,
      "status" => "accepted",
      "duplicate" => false
    }

    assert {:ok, ^body} =
             JobContract.validate_accepted(
               "job-123",
               1,
               body
             )
  end

  test "accepts a correlated duplicate acknowledgement" do
    body = %{
      "job_id" => "job-123",
      "attempt" => 1,
      "status" => "accepted",
      "duplicate" => true
    }

    assert {:ok, ^body} =
             JobContract.validate_accepted(
               "job-123",
               1,
               body
             )
  end

  test "rejects acknowledgement contract drift" do
    body = %{
      "job_id" => "job-123",
      "attempt" => 1,
      "status" => "accepted"
    }

    assert {:error,
            {
              :invalid_ai_job_ack,
              :contract_violation,
              errors
            }} =
             JobContract.validate_accepted(
               "job-123",
               1,
               body
             )

    assert is_list(errors)
    assert errors != []
  end

  test "rejects acknowledgement for another job" do
    body = %{
      "job_id" => "job-999",
      "attempt" => 1,
      "status" => "accepted",
      "duplicate" => false
    }

    assert {:error,
            {
              :invalid_ai_job_ack,
              :job_id_mismatch,
              "job-123",
              "job-999"
            }} =
             JobContract.validate_accepted(
               "job-123",
               1,
               body
             )
  end

  test "rejects acknowledgement for another attempt" do
    body = %{
      "job_id" => "job-123",
      "attempt" => 2,
      "status" => "accepted",
      "duplicate" => false
    }

    assert {:error,
            {
              :invalid_ai_job_ack,
              :attempt_mismatch,
              1,
              2
            }} =
             JobContract.validate_accepted(
               "job-123",
               1,
               body
             )
  end
end
