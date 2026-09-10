defmodule ItsmBackend.Jobs.CompletionContractTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.Jobs.CompletionContract

  # ------------------------------------------------------------
  # AI -> Phoenix completion
  # ------------------------------------------------------------

  test "accepts completed completion payload" do
    payload = %{
      "attempt" => 1,
      "status" => "completed",
      "selected_agent" => "account",
      "proposed_tool" => nil,
      "result" => %{
        "answer" => "Account is enabled."
      }
    }

    assert {:ok, ^payload} =
             CompletionContract.validate(payload)
  end

  test "accepts waiting approval with valid tool proposal" do
    payload = %{
      "attempt" => 1,
      "status" => "waiting_approval",
      "selected_agent" => "developer",
      "proposed_tool" => %{
        "tool" => "workspace_mkdir",
        "arguments" => %{
          "directory_name" => "demo"
        },
        "approval_id" => "approval-123"
      },
      "result" => %{
        "status" => "approval_required"
      }
    }

    assert {:ok, ^payload} =
             CompletionContract.validate(payload)
  end

  test "accepts failed completion payload" do
    payload = %{
      "attempt" => 1,
      "status" => "failed",
      "selected_agent" => nil,
      "proposed_tool" => nil,
      "error" => "AI execution failed."
    }

    assert {:ok, ^payload} =
             CompletionContract.validate(payload)
  end

  test "rejects completed payload without result" do
    assert {:error,
            {
              :invalid_ai_job_completion,
              :contract_violation,
              errors
            }} =
             CompletionContract.validate(%{
               "attempt" => 1,
               "status" => "completed",
               "selected_agent" => "account",
               "proposed_tool" => nil
             })

    assert is_list(errors)
    assert errors != []
  end

  test "rejects completion envelope drift" do
    assert {:error,
            {
              :invalid_ai_job_completion,
              :contract_violation,
              errors
            }} =
             CompletionContract.validate(%{
               "attempt" => 1,
               "status" => "completed",
               "selected_agent" => "account",
               "proposed_tool" => nil,
               "result" => %{},
               "debug" => true
             })

    assert is_list(errors)
    assert errors != []
  end

  test "rejects malformed nested tool proposal" do
    assert {:error,
            {
              :invalid_ai_job_completion,
              :tool_proposal_contract_violation,
              errors
            }} =
             CompletionContract.validate(%{
               "attempt" => 1,
               "status" => "waiting_approval",
               "selected_agent" => "developer",
               "proposed_tool" => %{
                 "tool" => "workspace_mkdir"
               },
               "result" => %{
                 "status" => "approval_required"
               }
             })

    assert is_list(errors)
    assert errors != []
  end

  test "rejects non-map payload" do
    assert {:error,
            {
              :invalid_ai_job_completion,
              :invalid_payload_type,
              "invalid"
            }} =
             CompletionContract.validate("invalid")
  end

  # ------------------------------------------------------------
  # Phoenix -> AI completion acknowledgement
  # ------------------------------------------------------------

  test "builds applied completion acknowledgement" do
    assert {:ok,
            %{
              "job_id" => "job-123",
              "status" => "completed",
              "acknowledgement" => "applied"
            }} =
             CompletionContract.build_ack(
               "job-123",
               "completed",
               :applied
             )
  end

  test "builds duplicate completion acknowledgement" do
    assert {:ok,
            %{
              "job_id" => "job-123",
              "status" => "failed",
              "acknowledgement" => "duplicate"
            }} =
             CompletionContract.build_ack(
               "job-123",
               "failed",
               :duplicate
             )
  end

  test "allows waiting approval acknowledgement" do
    assert {:ok,
            %{
              "job_id" => "job-123",
              "status" => "waiting_approval",
              "acknowledgement" => "applied"
            }} =
             CompletionContract.build_ack(
               "job-123",
               "waiting_approval",
               :applied
             )
  end

  test "rejects acknowledgement for non-completion lifecycle state" do
    assert {:error,
            {
              :invalid_ai_job_completion_ack,
              :contract_violation,
              errors
            }} =
             CompletionContract.build_ack(
               "job-123",
               "processing",
               :applied
             )

    assert is_list(errors)
    assert errors != []
  end

  test "rejects unknown acknowledgement disposition" do
    assert {:error,
            {
              :invalid_ai_job_completion_ack,
              :invalid_disposition,
              :ignored
            }} =
             CompletionContract.build_ack(
               "job-123",
               "completed",
               :ignored
             )
  end

  test "rejects acknowledgement with blank job id" do
    assert {:error,
            {
              :invalid_ai_job_completion_ack,
              :contract_violation,
              errors
            }} =
             CompletionContract.build_ack(
               "",
               "completed",
               :applied
             )

    assert is_list(errors)
    assert errors != []
  end
end
