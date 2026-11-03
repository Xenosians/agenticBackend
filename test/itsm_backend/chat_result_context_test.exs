defmodule ItsmBackend.ChatResultContextTest do
  @moduledoc """
  A saved job's structured result and approval receipt reach the AI with the
  next turn of the same chat (3 November, SUP-23). Without them Janus saw only
  its earlier prose and retracted a provider-verified ticket. The projection is
  bounded, the owner's own chat only, and never turns a failed or unknown
  outcome into a success.
  """
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.AIClient.JobContract
  alias ItsmBackend.Chats
  alias ItsmBackend.Jobs.{Job, SurrealStore}
  alias ItsmBackendWeb.AuthTestSupport

  @receipt %{
    "status" => "success",
    "issue_key" => "SUP-23",
    "verification_ok" => true
  }

  defp saved_job(identity, attrs) do
    {:ok, job} =
      Job.new(%{
        "user_id" => identity.user["user_id"],
        "conversation_id" => identity.chat["chat_id"],
        "message" => Map.get(attrs, :message, "Create a ticket for the VPN outage")
      })

    stored = %{
      job
      | status: Map.get(attrs, :status, "completed"),
        result: Map.get(attrs, :result),
        proposed_tool: Map.get(attrs, :proposed_tool)
    }

    {:ok, _} = SurrealStore.create(stored)
    stored
  end

  defp context(identity) do
    {:ok, turns} =
      Chats.ai_context(identity.user["user_id"], identity.chat["chat_id"], nil, 24)

    turns
  end

  defp evidence(turns) do
    turns |> Enum.map(& &1["result_evidence"]) |> Enum.reject(&is_nil/1)
  end

  defp approved(execution_status, extra \\ %{}) do
    Map.merge(
      %{
        "execution_status" => execution_status,
        "approval_status" => "approved",
        "approval_id" => "approval-1",
        "result" => @receipt
      },
      extra
    )
  end

  test "a verified approval receipt is carried on the assistant turn of the next request" do
    identity = AuthTestSupport.authenticated_identity!()

    saved_job(identity, %{
      result: %{
        "answer" => "Ticket created and verified.",
        "approval_execution" => approved("succeeded")
      },
      proposed_tool: %{"tool" => "ticket_create"}
    })

    turns = context(identity)
    assert [%{"role" => "user"}, %{"role" => "assistant"} = assistant] = turns
    receipt = assistant["result_evidence"]["approval_execution"]
    assert receipt["execution_status"] == "succeeded"
    assert receipt["tool"] == "ticket_create"
    assert receipt["result"] == @receipt
    assert assistant["result_evidence"]["job_status"] == "completed"
    refute Map.has_key?(hd(turns), "result_evidence")
  end

  test "a failed or unknown execution never carries its result as if it succeeded" do
    identity = AuthTestSupport.authenticated_identity!()

    for status <- ["failed", "outcome_unknown"] do
      saved_job(identity, %{
        message: "Create a ticket (#{status})",
        result: %{"answer" => "Not done.", "approval_execution" => approved(status)}
      })
    end

    for record <- evidence(context(identity)) do
      receipt = record["approval_execution"]
      assert receipt["execution_status"] in ["failed", "outcome_unknown"]
      refute Map.has_key?(receipt, "result")
      assert receipt["details_omitted"] == true
    end

    assert length(evidence(context(identity))) == 2
  end

  test "a job with no structured result adds no evidence, and malformed results are dropped" do
    identity = AuthTestSupport.authenticated_identity!()
    saved_job(identity, %{result: %{"answer" => "Plain answer."}})

    saved_job(identity, %{
      message: "Second request",
      result: %{
        "answer" => "Odd.",
        "results" => ["not a map", %{"status" => "success"}],
        "approval_execution" => %{"execution_status" => "succeeded"}
      }
    })

    assert evidence(context(identity)) == []
  end

  test "a large saved result keeps its outcome and marks the details omitted" do
    identity = AuthTestSupport.authenticated_identity!()

    saved_job(identity, %{
      result: %{
        "answer" => "Read the router.",
        "results" => [
          %{
            "agent_name" => "networking",
            "status" => "success",
            "proposed_tool" => "router_interfaces",
            "tool_result" => %{"rows" => List.duplicate(String.duplicate("r", 200), 100)}
          }
        ]
      }
    })

    [record] = evidence(context(identity))
    [result] = record["results"]
    assert result["status"] == "success" and result["proposed_tool"] == "router_interfaces"
    refute Map.has_key?(result, "tool_result")
    assert result["details_omitted"] == true
  end

  test "a result saved without an answer still reaches the next turn through a neutral carrier" do
    identity = AuthTestSupport.authenticated_identity!()

    saved_job(identity, %{
      result: %{
        "results" => [
          %{"agent_name" => "service-desk", "status" => "success", "outcome_code" => "read"}
        ]
      }
    })

    assistant = Enum.find(context(identity), &(&1["role"] == "assistant"))
    assert assistant["content"] == "A structured historical result record is attached."
    assert [%{"agent_name" => "service-desk"}] = assistant["result_evidence"]["results"]
  end

  test "another account's chat history never reaches this context" do
    owner = AuthTestSupport.authenticated_identity!()
    other = AuthTestSupport.authenticated_identity!()

    saved_job(other, %{
      result: %{"answer" => "Other account.", "approval_execution" => approved("succeeded")}
    })

    {:ok, turns} = Chats.ai_context(owner.user["user_id"], other.chat["chat_id"], nil, 24)
    assert evidence(turns) == []
  end

  test "the projected context is a valid AI job request under the internal contract" do
    identity = AuthTestSupport.authenticated_identity!()

    saved_job(identity, %{
      result: %{
        "answer" => "Ticket created and verified.",
        "results" => [
          %{"agent_name" => "service-desk", "status" => "success", "tool_result" => @receipt}
        ],
        "approval_execution" => approved("succeeded", %{"replayed" => false})
      },
      proposed_tool: %{"tool" => "ticket_create"}
    })

    turns = context(identity)

    assert {:ok, payload} =
             JobContract.build_execute_request(
               "job-next",
               1,
               identity.user["user_id"],
               "Did you create the ticket?",
               turns
             )

    assert [
             _user,
             %{"result_evidence" => %{"approval_execution" => %{"tool" => "ticket_create"}}}
           ] =
             payload["context"]
  end
end
