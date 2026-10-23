defmodule ItsmBackend.WorkflowContractFixture do
  @moduledoc false

  def contract do
    %{
      "version" => 1,
      "steps" => [
        %{
          "id" => "account",
          "capability" => "create_user_account",
          "grounded_arguments" => %{"user_id" => ["alice"], "first_name" => ["Zoë", "東京"]},
          "after_success_of" => nil
        },
        %{
          "id" => "ticket",
          "capability" => "jira_create_issue",
          "grounded_arguments" => %{"project_key" => ["LAB"]},
          "after_success_of" => "account"
        }
      ]
    }
  end

  def binding do
    {:ok, contract, hash} = ItsmBackend.Jobs.WorkflowContract.validate(contract())
    %{"workflow_contract" => contract, "workflow_contract_hash" => hash}
  end
end
