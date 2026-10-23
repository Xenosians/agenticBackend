defmodule ItsmBackend.Jobs.WorkflowContractTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.Jobs.{Job, PublicContract, WorkflowContract}
  alias ItsmBackend.WorkflowContractFixture, as: Fixture

  test "absent workflows preserve legacy submission behavior" do
    assert {:ok, nil, nil} = WorkflowContract.validate(nil)
    assert {:ok, job} = Job.new(%{user_id: "owner", message: "Check service"})
    assert job.workflow_contract == nil
    assert job.workflow_contract_hash == nil
  end

  test "digest has a language-neutral array projection, Unicode and exact target order" do
    contract = Fixture.contract()

    projection = [
      "itsm-requested-workflow.v1",
      1,
      [
        [
          "account",
          "create_user_account",
          [["first_name", ["Zoë", "東京"]], ["user_id", ["alice"]]],
          nil
        ],
        ["ticket", "jira_create_issue", [["project_key", ["LAB"]]], "account"]
      ]
    ]

    expected = :crypto.hash(:sha256, Jason.encode!(projection)) |> Base.encode16(case: :lower)
    # Independently reproduced with Python hashlib and compact UTF-8 json.dumps.
    assert expected == "f0db00b4bcfef4a16e1e089c355172ba6e3a52f6c88fc4a3322a19272f3be00e"
    assert {:ok, ^contract, ^expected} = WorkflowContract.validate(contract)
    assert :ok = WorkflowContract.validate_binding(contract, expected)

    changed =
      put_in(contract, ["steps", Access.at(0), "grounded_arguments", "first_name"], ["東京", "Zoë"])

    assert {:ok, _, different} = WorkflowContract.validate(changed)
    refute different == expected
  end

  test "targets are never trimmed and object-key insertion order does not affect digest" do
    contract = Fixture.contract()
    assert {:ok, _, first_hash} = WorkflowContract.validate(contract)

    reversed_map =
      contract["steps"] |> hd() |> Map.fetch!("grounded_arguments") |> Enum.reverse() |> Map.new()

    reordered = put_in(contract, ["steps", Access.at(0), "grounded_arguments"], reversed_map)
    assert {:ok, _, ^first_hash} = WorkflowContract.validate(reordered)

    changed =
      put_in(contract, ["steps", Access.at(0), "grounded_arguments", "user_id"], [" alice "])

    assert {:ok, ^changed, new_hash} = WorkflowContract.validate(changed)
    refute first_hash == new_hash
  end

  test "shared AI/backend Unicode vector has the same canonical digest" do
    contract = %{
      "version" => 1,
      "steps" => [
        %{
          "id" => "identity",
          "capability" => "account_create",
          "grounded_arguments" => %{"given_name" => ["Zoë", "李"], "family_name" => ["山田"]},
          "after_success_of" => nil
        },
        %{
          "id" => "ticket",
          "capability" => "ticket_create",
          "grounded_arguments" => %{"project_key" => ["SUP"]},
          "after_success_of" => "identity"
        }
      ]
    }

    assert {:ok, _, "37d95a5bf9eb19950cbd72bb05bc960aa1a283dc54d6783db73226054aa8f5cf"} =
             WorkflowContract.validate(contract)
  end

  test "create acknowledgement echoes a validated persisted pair and rejects mismatched digests" do
    binding = Fixture.binding()

    assert {:ok, payload} =
             PublicContract.build_create_response(
               "job",
               "pending",
               nil,
               binding["workflow_contract"],
               binding["workflow_contract_hash"]
             )

    assert payload["workflow_contract"] == binding["workflow_contract"]
    assert payload["workflow_contract_hash"] == binding["workflow_contract_hash"]

    assert {:error, _} =
             PublicContract.build_create_response(
               "job",
               "pending",
               nil,
               binding["workflow_contract"],
               String.duplicate("0", 64)
             )

    assert {:ok, legacy} = PublicContract.build_create_response("job", "pending")
    refute Map.has_key?(legacy, "workflow_contract")
    refute Map.has_key?(legacy, "workflow_contract_hash")
  end

  test "rejects duplicate operations, duplicate ids and unavailable dependency order" do
    contract = Fixture.contract()

    for changed <- [
          put_in(contract, ["steps", Access.at(1), "id"], "account"),
          put_in(contract, ["steps", Access.at(1), "capability"], "create_user_account"),
          put_in(contract, ["steps", Access.at(0), "after_success_of"], "ticket"),
          put_in(contract, ["steps", Access.at(1), "after_success_of"], "missing")
        ] do
      assert {:error, {:invalid_field, :workflow_contract}} = WorkflowContract.validate(changed)
    end
  end

  test "rejects wrong types, extra authority fields, invalid identifiers and empty targets" do
    contract = Fixture.contract()

    for changed <- [
          Map.put(contract, "version", 1.0),
          Map.put(contract, "permission", "all"),
          Map.put(contract, "steps", []),
          put_in(contract, ["steps", Access.at(0), "permission"], "all"),
          put_in(contract, ["steps", Access.at(0), "id"], "bad id"),
          put_in(contract, ["steps", Access.at(0), "capability"], ""),
          put_in(contract, ["steps", Access.at(0), "grounded_arguments"], %{"bad key" => ["x"]}),
          put_in(contract, ["steps", Access.at(0), "grounded_arguments"], %{"user_id" => []}),
          put_in(contract, ["steps", Access.at(0), "grounded_arguments"], %{"user_id" => [""]}),
          put_in(contract, ["steps", Access.at(0), "grounded_arguments"], %{"user_id" => [12]})
        ] do
      assert {:error, {:invalid_field, :workflow_contract}} = WorkflowContract.validate(changed)
    end
  end

  test "enforces entry, string and entire UTF-8 request budgets" do
    contract = Fixture.contract()

    for arguments <- [
          Map.new(1..33, &{"key_#{&1}", ["target"]}),
          %{"user_id" => List.duplicate("x", 17)},
          %{"user_id" => [String.duplicate("x", 1025)]},
          Map.new(1..3, &{"key_#{&1}", List.duplicate(String.duplicate("東", 1024), 16)})
        ] do
      assert {:error, {:invalid_field, :workflow_contract}} =
               WorkflowContract.validate(
                 put_in(contract, ["steps", Access.at(0), "grounded_arguments"], arguments)
               )
    end
  end

  test "empty grounded arguments pin only operations and dependency" do
    contract = put_in(Fixture.contract(), ["steps", Access.at(0), "grounded_arguments"], %{})
    assert {:ok, ^contract, _} = WorkflowContract.validate(contract)
  end

  test "accepts eight explicitly ordered steps and rejects a ninth" do
    steps =
      Enum.map(1..9, fn index ->
        %{
          "id" => "step#{index}",
          "capability" => "operation_#{index}",
          "grounded_arguments" => %{},
          "after_success_of" => if(index == 1, do: nil, else: "step#{index - 1}")
        }
      end)

    assert {:ok, _, _} =
             WorkflowContract.validate(%{"version" => 1, "steps" => Enum.take(steps, 8)})

    assert {:error, {:invalid_field, :workflow_contract}} =
             WorkflowContract.validate(%{"version" => 1, "steps" => steps})
  end

  test "public contract never accepts a browser-computed digest or malformed semantic order" do
    payload = %{
      "chat_id" => "chat",
      "message" => "Create account then ticket",
      "workflow_contract" => Fixture.contract()
    }

    assert {:ok, ^payload} = PublicContract.validate_create_request(payload)

    assert {:error, _} =
             PublicContract.validate_create_request(
               Map.put(payload, "workflow_contract_hash", String.duplicate("a", 64))
             )

    assert {:error, _} =
             PublicContract.validate_create_request(
               put_in(
                 payload,
                 ["workflow_contract", "steps", Access.at(0), "after_success_of"],
                 "ticket"
               )
             )
  end
end
