defmodule ItsmBackend.Jobs.PublicContractTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.Jobs.PublicContract

  test "accepts current authenticated create request" do
    payload = %{
      "chat_id" => "chat-123",
      "message" => "Check my account."
    }

    assert {:ok, ^payload} =
             PublicContract.validate_create_request(payload)
  end

  test "rejects blank chat id" do
    assert {:error,
            {
              :invalid_job_create_request,
              :contract_violation,
              errors
            }} =
             PublicContract.validate_create_request(%{
               "chat_id" => "",
               "message" => "hello"
             })

    assert is_list(errors)
    assert errors != []
  end

  test "rejects browser supplied user authority" do
    assert {:error,
            {
              :invalid_job_create_request,
              :contract_violation,
              errors
            }} =
             PublicContract.validate_create_request(%{
               "chat_id" => "chat-123",
               "message" => "hello",
               "user_id" => "forged-user"
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
               "chat_id" => "chat-123",
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

  test "accepts a pinned submission UUID and rejects malformed identities" do
    payload = %{
      "chat_id" => "chat-123",
      "message" => "Check status",
      "submission_id" => ItsmBackend.SubmissionTestSupport.identity()
    }

    assert {:ok, ^payload} = PublicContract.validate_create_request(payload)

    for identity <- ["", "not-a-uuid", 123, nil] do
      assert {:error, {:invalid_job_create_request, :contract_violation, _}} =
               PublicContract.validate_create_request(%{payload | "submission_id" => identity})
    end
  end

  test "a recovered submission acknowledges its current state and exact identity" do
    identity = ItsmBackend.SubmissionTestSupport.identity()

    for status <- [
          "processing",
          "waiting_approval",
          "completed",
          "failed",
          "denied",
          "outcome_unknown"
        ] do
      assert {:ok, %{"job_id" => "job-123", "status" => ^status, "submission_id" => ^identity}} =
               PublicContract.build_create_response("job-123", status, identity)
    end
  end

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
