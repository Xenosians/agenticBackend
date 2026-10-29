defmodule ItsmBackendWeb.SubmissionIntentControllerTest do
  use ItsmBackendWeb.ConnCase, async: false
  alias ItsmBackend.{Jobs, SubmissionIntents, Surreal, Workflows}
  alias ItsmBackendWeb.AuthTestSupport

  setup do
    %{owner: AuthTestSupport.authenticated_identity!()}
  end

  defp bearer(owner), do: AuthTestSupport.bearer_conn(build_conn(), owner.auth.raw_token)

  defp proposal(owner),
    do: %{"chat_id" => owner.chat["chat_id"], "message" => "Read the reviewed inventory"}

  defp reserve(owner, request, previous \\ nil) do
    bearer(owner)
    |> post("/api/v1/submission-intents", %{
      "kind" => "chat",
      "target_id" => owner.chat["chat_id"],
      "expected_id" => previous,
      "request" => request
    })
  end

  defp read(owner),
    do:
      bearer(owner)
      |> get("/api/v1/submission-intents?kind=chat&target_id=#{owner.chat["chat_id"]}")

  defp acknowledge(owner, id),
    do:
      bearer(owner)
      |> post("/api/v1/submission-intents/acknowledge", %{
        "kind" => "chat",
        "target_id" => owner.chat["chat_id"],
        "intent_id" => id
      })

  defp accept(owner, intent) do
    request = intent["request"]

    Jobs.create(
      Map.merge(request, %{
        "user_id" => owner.user["user_id"],
        "conversation_id" => owner.chat["chat_id"]
      })
    )
  end

  test "routes declare their exact arguments" do
    contracts =
      ItsmBackendWeb.ApiContract.audit!()
      |> Enum.filter(&String.starts_with?(&1.path, "/api/v1/submission-intents"))
      |> Map.new(&{{&1.method, &1.path}, &1})

    show = contracts[{"GET", "/api/v1/submission-intents"}]
    assert Enum.sort(show.required_query_params) == ~w(kind target_id)
    assert show.effect == "read"

    reserve = contracts[{"POST", "/api/v1/submission-intents"}]
    assert Enum.sort(reserve.required_body_params) == ~w(expected_id kind request target_id)
    assert reserve.effect == "mutation"

    acknowledge = contracts[{"POST", "/api/v1/submission-intents/acknowledge"}]
    assert Enum.sort(acknowledge.required_body_params) == ~w(intent_id kind target_id)
    assert acknowledge.effect == "mutation"
  end

  test "only Phoenix's refusal of the exact request releases it before admission", %{
    owner: owner
  } do
    original = reserve(owner, proposal(owner)) |> json_response(200) |> Map.fetch!("intent")
    request = original["request"]

    # A different payload reusing the identity can never release the original.
    assert {:error, :intent_unavailable} =
             SubmissionIntents.record_rejection(
               owner.user,
               "chat",
               owner.chat["chat_id"],
               Map.put(request, "message", "A different message"),
               "chat_not_found"
             )

    assert read(owner) |> json_response(200) |> get_in(["intent", "state"]) == "pending"

    # The exact request, refused before any job exists, releases the slot.
    assert {:ok, _} =
             Surreal.query("DELETE type::record('chat', $id);", %{"id" => owner.chat["chat_id"]})

    assert bearer(owner) |> post("/api/v1/jobs", request) |> json_response(404)
    released = read(owner) |> json_response(200) |> Map.fetch!("intent")
    assert released["state"] == "rejected"
    assert released["receipt"] == %{"error" => "chat_not_found"}
  end

  test "a reviewed contract with a null dependency is stored exactly and released only exactly",
       %{owner: owner} do
    contract = %{
      "version" => 1,
      "steps" => [
        %{
          "id" => "account",
          "capability" => "account_create",
          "grounded_arguments" => %{"given_name" => [" Exact "]},
          "after_success_of" => nil
        }
      ]
    }

    proposal = Map.put(proposal(owner), "workflow_contract", contract)
    original = reserve(owner, proposal) |> json_response(200) |> Map.fetch!("intent")
    assert read(owner) |> json_response(200) |> Map.fetch!("intent") == original
    assert original["request"]["workflow_contract"] == contract

    assert {:ok, _} =
             Surreal.query("DELETE type::record('chat', $id);", %{"id" => owner.chat["chat_id"]})

    assert bearer(owner) |> post("/api/v1/jobs", original["request"]) |> json_response(404)
    assert read(owner) |> json_response(200) |> get_in(["intent", "state"]) == "rejected"
  end

  test "an admitted job is never released by a later refusal", %{owner: owner} do
    original = reserve(owner, proposal(owner)) |> json_response(200) |> Map.fetch!("intent")
    assert {:ok, _job} = accept(owner, original)

    assert {:error, :intent_unavailable} =
             SubmissionIntents.record_rejection(
               owner.user,
               "chat",
               owner.chat["chat_id"],
               original["request"],
               "chat_not_found"
             )

    assert read(owner) |> json_response(200) |> get_in(["intent", "state"]) == "pending"
  end

  test "a workflow run refused before admission releases its exact request", %{owner: owner} do
    definition = %{
      "version" => 1,
      "steps" => [
        %{
          "id" => "read",
          "capability" => "inventory_read",
          "grounded_arguments" => %{},
          "after_success_of" => nil
        }
      ]
    }

    {:ok, workflow} =
      Workflows.create(owner.user, %{
        "name" => "Read inventory",
        "definition" => definition,
        "layout" => %{"read" => %{"x" => 0, "y" => 0}}
      })

    id = workflow["workflow_id"]
    request = %{"version" => workflow["version"], "message" => "Read the reviewed inventory"}
    {:ok, slot} = SubmissionIntents.reserve(owner.user, "workflow", id, request, nil)

    {:ok, _} =
      Workflows.update(owner.user, id, %{
        "name" => "Read inventory v2",
        "definition" => definition,
        "layout" => %{"read" => %{"x" => 0, "y" => 0}},
        "base_version" => workflow["version"]
      })

    assert bearer(owner)
           |> post("/api/v1/workflows/#{id}/runs", slot["intent"]["request"])
           |> json_response(409)

    assert {:ok, %{"intent" => %{"state" => "rejected"}}} =
             SubmissionIntents.get(owner.user, "workflow", id)
  end

  test "reservation lost before dispatch remains exact after a new authenticated read", %{
    owner: owner
  } do
    original = reserve(owner, proposal(owner)) |> json_response(200) |> Map.fetch!("intent")
    recovered = read(owner) |> json_response(200) |> Map.fetch!("intent")
    assert recovered == original
    assert recovered["state"] == "pending"
    assert recovered["request"]["submission_id"] =~ ~r/\A[0-9a-f-]{36}\z/

    assert acknowledge(owner, original["intent_id"]) |> json_response(503) |> Map.fetch!("error") ==
             "submission_intent_unavailable"

    assert read(owner) |> json_response(200) |> get_in(["intent", "state"]) == "pending"

    assert reserve(owner, Map.put(proposal(owner), "message", "Another request"))
           |> json_response(409)
  end

  test "lost acceptance reply reconciles original job; an intentional next request needs predecessor CAS",
       %{owner: owner} do
    original = reserve(owner, proposal(owner)) |> json_response(200) |> Map.fetch!("intent")
    assert {:ok, job} = accept(owner, original)
    assert job.status == "pending"

    assert read(owner) |> json_response(200) |> get_in(["intent", "intent_id"]) ==
             original["intent_id"]

    accepted =
      acknowledge(owner, original["intent_id"]) |> json_response(200) |> Map.fetch!("intent")

    assert accepted["state"] == "acknowledged"
    assert accepted["receipt"]["job_id"] == job.id
    assert accepted["receipt"]["submission_id"] == original["request"]["submission_id"]
    assert reserve(owner, proposal(owner)) |> json_response(409)

    next =
      reserve(owner, proposal(owner), original["intent_id"])
      |> json_response(200)
      |> Map.fetch!("intent")

    refute next["intent_id"] == original["intent_id"]
    # Delayed acknowledgement cannot clear a newer pending request.
    assert acknowledge(owner, original["intent_id"]) |> json_response(409)

    assert read(owner) |> json_response(200) |> get_in(["intent", "intent_id"]) ==
             next["intent_id"]

    # Lost reservation reply is recovered with the same predecessor, not a third request.
    assert reserve(owner, proposal(owner), original["intent_id"])
           |> json_response(200)
           |> get_in(["intent", "intent_id"]) == next["intent_id"]
  end

  test "concurrent tabs reserve one identity and a distinct request conflicts", %{owner: owner} do
    results =
      1..6
      |> Task.async_stream(
        fn _ ->
          SubmissionIntents.reserve(
            owner.user,
            "chat",
            owner.chat["chat_id"],
            proposal(owner),
            nil
          )
        end,
        ordered: false
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    ids = Enum.map(results, fn {:ok, {:ok, slot}} -> slot["intent"]["intent_id"] end)
    assert length(Enum.uniq(ids)) == 1

    assert {:error, :pending_intent} =
             SubmissionIntents.reserve(
               owner.user,
               "chat",
               owner.chat["chat_id"],
               Map.put(proposal(owner), "message", "Different"),
               nil
             )
  end

  test "owner, CSRF and malformed requests cannot borrow or acknowledge an intent", %{
    owner: owner
  } do
    intent = reserve(owner, proposal(owner)) |> json_response(200) |> Map.fetch!("intent")
    other = AuthTestSupport.authenticated_identity!()

    assert {:ok, %{"intent" => nil}} =
             SubmissionIntents.get(other.user, "chat", owner.chat["chat_id"])

    assert {:error, _} =
             SubmissionIntents.acknowledge(
               other.user,
               "chat",
               owner.chat["chat_id"],
               intent["intent_id"]
             )

    assert build_conn()
           |> get("/api/v1/submission-intents?kind=chat&target_id=#{owner.chat["chat_id"]}")
           |> json_response(401)

    assert reserve(owner, Map.put(proposal(owner), "user_id", other.user["user_id"]))
           |> json_response(409)

    assert bearer(owner)
           |> get("/api/v1/submission-intents?kind=chat&target_id=invalid")
           |> json_response(422)
  end

  test "corrupt storage is unavailable and never becomes an empty slot", %{owner: owner} do
    reserve(owner, proposal(owner)) |> json_response(200)

    assert {:ok, _} =
             Surreal.query(
               "UPDATE submission_intent SET request_sha256 = 'changed' WHERE user_id = $owner;",
               %{"owner" => owner.user["user_id"]}
             )

    assert read(owner) |> json_response(503)
    assert reserve(owner, proposal(owner)) |> json_response(503)
  end

  test "workflow intent acknowledges the original immutable ordinary job", %{owner: owner} do
    definition = %{
      "version" => 1,
      "steps" => [
        %{
          "id" => "read",
          "capability" => "inventory_read",
          "grounded_arguments" => %{},
          "after_success_of" => nil
        }
      ]
    }

    assert {:ok, workflow} =
             Workflows.create(owner.user, %{
               "name" => "Read inventory",
               "definition" => definition,
               "layout" => %{"read" => %{"x" => 0, "y" => 0}}
             })

    request = %{"version" => workflow["version"], "message" => "Read the reviewed inventory"}

    assert {:ok, slot} =
             SubmissionIntents.reserve(
               owner.user,
               "workflow",
               workflow["workflow_id"],
               request,
               nil
             )

    intent = slot["intent"]
    assert intent["context"]["definition"] == definition

    assert {:error, :intent_outcome_unknown} =
             SubmissionIntents.acknowledge(
               owner.user,
               "workflow",
               workflow["workflow_id"],
               intent["intent_id"]
             )

    assert {:ok, _, job, _} =
             Workflows.run(owner.user, workflow["workflow_id"], intent["request"])

    assert {:ok, resolved} =
             SubmissionIntents.acknowledge(
               owner.user,
               "workflow",
               workflow["workflow_id"],
               intent["intent_id"]
             )

    assert resolved["intent"]["receipt"]["job_id"] == job.id
    assert resolved["intent"]["receipt"]["workflow_version"] == workflow["version"]
  end
end
