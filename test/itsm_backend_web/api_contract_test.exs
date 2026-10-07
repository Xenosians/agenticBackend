defmodule ItsmBackendWeb.ApiContractTest do
  use ExUnit.Case, async: true

  alias ItsmBackendWeb.ApiContract

  test "every public and internal API route has normalized CRUD/action and argument contracts" do
    contracts = ApiContract.audit!()

    assert contracts != []

    Enum.each(contracts, fn contract ->
      assert contract.resource_type not in [nil, ""]
      assert contract.operation_kind in ~w(create read update delete search action)
      assert contract.effect in ~w(read mutation)
      assert is_binary(contract.permission)
      assert String.contains?(contract.permission, ".")
      assert contract.argument_contract_source == "controller_request_contract_v1"
      assert is_list(contract.required_path_params)
      assert is_list(contract.required_body_params)
      assert is_list(contract.optional_body_params)
      assert is_list(contract.required_query_params)
      assert is_list(contract.optional_query_params)

      assert MapSet.disjoint?(
               MapSet.new(contract.required_body_params),
               MapSet.new(contract.optional_body_params)
             )

      assert MapSet.disjoint?(
               MapSet.new(contract.required_query_params),
               MapSet.new(contract.optional_query_params)
             )

      if contract.method == "GET" do
        assert contract.effect == "read"
      else
        assert contract.effect == "mutation"
      end
    end)
  end

  test "path parameters are deterministic required arguments of the HTTP boundary" do
    contracts = ApiContract.audit!()

    Enum.each(contracts, fn contract ->
      expected =
        Regex.scan(~r/:([A-Za-z0-9_]+)/, contract.path)
        |> Enum.map(fn [_whole, name] -> name end)

      assert contract.required_path_params == expected
    end)
  end

  test "durable job create request exposes its actual required body arguments" do
    contract =
      ApiContract.audit!()
      |> Enum.find(fn contract ->
        contract.method == "POST" and contract.path == "/api/v1/jobs"
      end)

    assert contract
    assert contract.operation_kind == "create"
    assert contract.required_body_params == ["chat_id", "message"]
    assert contract.optional_body_params == []
  end

  test "chat history exposes path and optional query arguments separately" do
    contract =
      ApiContract.audit!()
      |> Enum.find(fn contract ->
        contract.method == "GET" and contract.path == "/api/v1/chats/:id/history"
      end)

    assert contract
    assert contract.required_path_params == ["id"]
    assert contract.required_query_params == []
    assert contract.optional_query_params == ["limit"]
  end
end
