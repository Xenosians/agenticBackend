defmodule ItsmBackend.ContractsTest do
  use ExUnit.Case, async: true

  @contracts_root Path.expand(
                    "../../contracts/v1",
                    __DIR__
                  )

  @schemas %{
    error: "common/error.schema.json",
    tool_proposal: "common/tool-proposal.schema.json",
    job_create_request: "public/job-create-request.schema.json",
    job_response: "public/job-response.schema.json",
    ai_job_execute_request: "internal/ai-job-execute-request.schema.json",
    ai_job_completion: "internal/ai-job-completion.schema.json"
  }

  # ------------------------------------------------------------
  # Contract inventory
  # ------------------------------------------------------------

  test "v1 schema inventory matches the canonical contract set" do
    expected =
      @schemas
      |> Map.values()
      |> MapSet.new()

    actual =
      @contracts_root
      |> Path.join("**/*.schema.json")
      |> Path.wildcard()
      |> Enum.map(
        &Path.relative_to(
          &1,
          @contracts_root
        )
      )
      |> MapSet.new()

    assert actual == expected
  end

  # ------------------------------------------------------------
  # Schema compilation
  # ------------------------------------------------------------

  test "all v1 schemas compile as JSON Schema" do
    Enum.each(
      @schemas,
      fn {_name, relative_path} ->
        assert {:ok, _compiled} =
                 relative_path
                 |> load_schema()
                 |> JSONSchex.compile()
      end
    )
  end

  # ------------------------------------------------------------
  # Public job creation
  # ------------------------------------------------------------

  test "job-create-request accepts the current public payload" do
    assert_valid(
      :job_create_request,
      %{
        "user_id" => "jdoe",
        "message" => "Is my account locked?"
      }
    )
  end

  test "job-create-request accepts optional conversation_id" do
    assert_valid(
      :job_create_request,
      %{
        "user_id" => "jdoe",
        "conversation_id" => "conversation-1",
        "message" => "Continue the previous request."
      }
    )
  end

  test "job-create-request rejects missing required fields" do
    refute_valid(
      :job_create_request,
      %{
        "user_id" => "jdoe"
      }
    )
  end

  test "job-create-request rejects blank identifiers" do
    refute_valid(
      :job_create_request,
      %{
        "user_id" => "",
        "message" => "hello"
      }
    )
  end

  test "job-create-request rejects unknown fields" do
    refute_valid(
      :job_create_request,
      %{
        "user_id" => "jdoe",
        "message" => "hello",
        "unexpected" => true
      }
    )
  end

  # ------------------------------------------------------------
  # Public durable job response
  # ------------------------------------------------------------

  test "job-response accepts pending durable state" do
    assert_valid(
      :job_response,
      %{
        "job_id" => "job-123",
        "user_id" => "jdoe",
        "conversation_id" => nil,
        "message" => "hello",
        "status" => "pending",
        "attempts" => 0,
        "created_at" => "2026-09-10T04:00:00Z",
        "claimed_at" => nil,
        "lease_expires_at" => nil,
        "completed_at" => nil,
        "selected_agent" => nil,
        "proposed_tool" => nil,
        "result" => nil,
        "error" => nil
      }
    )
  end

  test "job-response accepts completed durable state" do
    assert_valid(
      :job_response,
      %{
        "job_id" => "job-123",
        "user_id" => "jdoe",
        "conversation_id" => "conversation-1",
        "message" => "Check account.",
        "status" => "completed",
        "attempts" => 1,
        "created_at" => "2026-09-10T04:00:00Z",
        "claimed_at" => "2026-09-10T04:00:01Z",
        "lease_expires_at" => nil,
        "completed_at" => "2026-09-10T04:00:02Z",
        "selected_agent" => "account",
        "proposed_tool" => nil,
        "result" => %{
          "answer" => "The account is enabled."
        },
        "error" => nil
      }
    )
  end

  test "job-response rejects unknown lifecycle status" do
    payload =
      valid_pending_job_response()
      |> Map.put(
        "status",
        "mystery"
      )

    refute_valid(
      :job_response,
      payload
    )
  end

  test "job-response rejects envelope drift" do
    payload =
      valid_pending_job_response()
      |> Map.put(
        "debug",
        true
      )

    refute_valid(
      :job_response,
      payload
    )
  end

  # ------------------------------------------------------------
  # Phoenix -> AI execution
  # ------------------------------------------------------------

  test "ai-job-execute-request accepts the current internal payload" do
    assert_valid(
      :ai_job_execute_request,
      %{
        "job_id" => "job-123",
        "attempt" => 1,
        "user_id" => "jdoe",
        "message" => "Check my account."
      }
    )
  end

  test "ai-job-execute-request rejects attempt zero" do
    refute_valid(
      :ai_job_execute_request,
      %{
        "job_id" => "job-123",
        "attempt" => 0,
        "user_id" => "jdoe",
        "message" => "Check my account."
      }
    )
  end

  test "ai-job-execute-request rejects unknown fields" do
    refute_valid(
      :ai_job_execute_request,
      %{
        "job_id" => "job-123",
        "attempt" => 1,
        "user_id" => "jdoe",
        "message" => "Check my account.",
        "retry" => true
      }
    )
  end

  # ------------------------------------------------------------
  # AI -> Phoenix completion
  # ------------------------------------------------------------

  test "ai-job-completion accepts completed result" do
    assert_valid(
      :ai_job_completion,
      %{
        "attempt" => 1,
        "status" => "completed",
        "selected_agent" => "account",
        "proposed_tool" => nil,
        "result" => %{
          "answer" => "The account is enabled."
        }
      }
    )
  end

  test "ai-job-completion accepts waiting approval result" do
    proposal = %{
      "tool" => "workspace_mkdir",
      "arguments" => %{
        "directory_name" => "demo_workspace"
      },
      "approval_id" => "approval-123"
    }

    assert_valid(
      :tool_proposal,
      proposal
    )

    assert_valid(
      :ai_job_completion,
      %{
        "attempt" => 1,
        "status" => "waiting_approval",
        "selected_agent" => "developer",
        "proposed_tool" => proposal,
        "result" => %{
          "status" => "approval_required"
        }
      }
    )
  end

  test "ai-job-completion accepts failed result" do
    assert_valid(
      :ai_job_completion,
      %{
        "attempt" => 1,
        "status" => "failed",
        "selected_agent" => nil,
        "proposed_tool" => nil,
        "error" => "AI job execution failed."
      }
    )
  end

  test "ai-job-completion rejects failed state without error" do
    refute_valid(
      :ai_job_completion,
      %{
        "attempt" => 1,
        "status" => "failed",
        "selected_agent" => nil,
        "proposed_tool" => nil
      }
    )
  end

  test "ai-job-completion rejects completed state without result" do
    refute_valid(
      :ai_job_completion,
      %{
        "attempt" => 1,
        "status" => "completed",
        "selected_agent" => nil,
        "proposed_tool" => nil
      }
    )
  end

  test "ai-job-completion rejects result on failed state" do
    refute_valid(
      :ai_job_completion,
      %{
        "attempt" => 1,
        "status" => "failed",
        "selected_agent" => nil,
        "proposed_tool" => nil,
        "result" => %{},
        "error" => "failure"
      }
    )
  end

  test "ai-job-completion rejects error on successful state" do
    refute_valid(
      :ai_job_completion,
      %{
        "attempt" => 1,
        "status" => "completed",
        "selected_agent" => nil,
        "proposed_tool" => nil,
        "result" => %{},
        "error" => "contradiction"
      }
    )
  end

  test "ai-job-completion rejects unsupported status" do
    refute_valid(
      :ai_job_completion,
      %{
        "attempt" => 1,
        "status" => "processing",
        "selected_agent" => nil,
        "proposed_tool" => nil,
        "result" => %{}
      }
    )
  end

  # ------------------------------------------------------------
  # Tool proposal
  # ------------------------------------------------------------

  test "tool-proposal accepts structured proposals" do
    assert_valid(
      :tool_proposal,
      %{
        "tool" => "workspace_mkdir",
        "arguments" => %{
          "directory_name" => "demo_workspace"
        },
        "approval_id" => "approval-123"
      }
    )
  end

  test "tool-proposal accepts read-only proposal without approval" do
    assert_valid(
      :tool_proposal,
      %{
        "tool" => "process_exec",
        "arguments" => %{
          "executable" => "pwd",
          "args" => []
        }
      }
    )
  end

  test "tool-proposal rejects a missing arguments object" do
    refute_valid(
      :tool_proposal,
      %{
        "tool" => "process_exec"
      }
    )
  end

  test "tool-proposal rejects envelope drift" do
    refute_valid(
      :tool_proposal,
      %{
        "tool" => "process_exec",
        "arguments" => %{},
        "authorized" => true
      }
    )
  end

  # ------------------------------------------------------------
  # Common error
  # ------------------------------------------------------------

  test "error contract accepts validation errors" do
    assert_valid(
      :error,
      %{
        "error" => "invalid_request",
        "field" => "message"
      }
    )
  end

  test "error contract accepts service errors" do
    assert_valid(
      :error,
      %{
        "error" => "job_creation_failed",
        "reason" => "storage unavailable"
      }
    )
  end

  test "error contract requires a machine-readable error code" do
    refute_valid(
      :error,
      %{
        "reason" => "something happened"
      }
    )
  end

  # ------------------------------------------------------------
  # Fixtures
  # ------------------------------------------------------------

  defp valid_pending_job_response do
    %{
      "job_id" => "job-123",
      "user_id" => "jdoe",
      "conversation_id" => nil,
      "message" => "hello",
      "status" => "pending",
      "attempts" => 0,
      "created_at" => "2026-09-10T04:00:00Z",
      "claimed_at" => nil,
      "lease_expires_at" => nil,
      "completed_at" => nil,
      "selected_agent" => nil,
      "proposed_tool" => nil,
      "result" => nil,
      "error" => nil
    }
  end

  # ------------------------------------------------------------
  # Validation helpers
  # ------------------------------------------------------------

  defp assert_valid(
         schema_name,
         payload
       ) do
    assert :ok ==
             schema_name
             |> compiled_schema()
             |> JSONSchex.validate(payload)
  end

  defp refute_valid(
         schema_name,
         payload
       ) do
    assert {:error, errors} =
             schema_name
             |> compiled_schema()
             |> JSONSchex.validate(payload)

    assert is_list(errors)
    assert errors != []
  end

  defp compiled_schema(schema_name) do
    relative_path =
      Map.fetch!(
        @schemas,
        schema_name
      )

    schema =
      load_schema(relative_path)

    {:ok, compiled} =
      JSONSchex.compile(schema)

    compiled
  end

  defp load_schema(relative_path) do
    path =
      Path.join(
        @contracts_root,
        relative_path
      )

    path
    |> File.read!()
    |> Jason.decode!()
  end
end
