defmodule ItsmBackend.AIClientContractTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.AIClient

  defmodule LegacyClient do
    def execute_job(job_id, attempt, user_id, message) do
      {:ok,
       %{
         job_id: job_id,
         attempt: attempt,
         user_id: user_id,
         message: message,
         context: :legacy
       }}
    end
  end

  defmodule ContextClient do
    def execute_job(job_id, attempt, user_id, message, context) do
      {:ok,
       %{
         job_id: job_id,
         attempt: attempt,
         user_id: user_id,
         message: message,
         context: context
       }}
    end
  end

  test "dispatches bounded context through execute_job/5" do
    context = [%{"role" => "user", "content" => "hello"}]

    assert {:ok, %{context: ^context}} =
             AIClient.dispatch_job(
               ContextClient,
               "job-1",
               1,
               "user-1",
               "hello",
               context
             )
  end

  test "legacy execute_job/4 remains valid only for empty context" do
    assert {:ok, %{context: :legacy}} =
             AIClient.dispatch_job(
               LegacyClient,
               "job-1",
               1,
               "user-1",
               "hello",
               []
             )
  end

  test "never silently drops non-empty context" do
    assert {:error,
            {
              :ai_client_missing_context_callback,
              LegacyClient
            }} =
             AIClient.dispatch_job(
               LegacyClient,
               "job-1",
               1,
               "user-1",
               "hello",
               [%{"role" => "user", "content" => "context"}]
             )
  end
end
