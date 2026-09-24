defmodule ItsmBackend.AIClient.ContextContractTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.AIClient.JobContract

  test "build_execute_request/5 carries bounded conversation context" do
    context = [
      %{"role" => "user", "content" => "Create Alice"},
      %{"role" => "assistant", "content" => "Alice created"}
    ]

    assert {:ok, payload} =
             JobContract.build_execute_request(
               "job-1",
               1,
               "user-1",
               "What account did you just create?",
               context
             )

    assert payload["context"] == context
  end

  test "legacy build_execute_request/4 remains valid and omits context" do
    assert {:ok, payload} =
             JobContract.build_execute_request(
               "job-1",
               1,
               "user-1",
               "hello"
             )

    refute Map.has_key?(payload, "context")
  end
end
