defmodule ItsmBackendWeb.OperationsTest do
  use ItsmBackendWeb.ConnCase, async: false
  alias ItsmBackend.{Jobs, Surreal}
  alias ItsmBackend.Jobs.Job
  alias ItsmBackendWeb.AuthTestSupport
  alias ItsmBackendWeb.StorageFaultProxy

  @token "operations-test-only-internal-token"

  setup do
    prior = Application.get_env(:itsm_backend, :internal_job_token)
    Application.put_env(:itsm_backend, :internal_job_token, @token)
    on_exit(fn -> Application.put_env(:itsm_backend, :internal_job_token, prior) end)
    %{owner: AuthTestSupport.authenticated_identity!()}
  end

  test "snapshot counts the owner's entire queue, independently of recent limit", %{owner: owner} do
    first = job(owner, "processing")
    _pending = job(owner, "pending")
    latest = job(owner, "waiting_approval")
    other = AuthTestSupport.authenticated_identity!()
    _other_job = job(other, "completed")

    body = owner |> conn_for() |> get("/api/v1/operations?limit=1") |> json_response(200)
    assert body["schema"] == "operations-snapshot.v1"
    assert {:ok, _, _} = DateTime.from_iso8601(body["observed_at"])
    assert body["counts"]["processing"] == 1
    assert body["counts"]["pending"] == 1
    assert body["counts"]["waiting_approval"] == 1
    assert Enum.sum(Map.values(body["counts"])) == 3
    assert [row] = body["jobs"]
    assert row["job_id"] == latest.id
    assert row["chat_id"] == owner.chat["chat_id"]
    assert row["metrics"] == []
    assert row["metrics_truncated"] == false
    assert is_number(row["queue_wait_ms"])
    assert is_number(row["elapsed_ms"])
    refute Jason.encode!(body) =~ "private request"
    refute Map.has_key?(row, "user_id")
    refute Map.has_key?(row, "proposed_tool")

    assert other
           |> conn_for()
           |> get("/api/v1/operations")
           |> json_response(200)
           |> get_in(["counts", "completed"]) == 1

    assert {:ok, ^first} = Jobs.get(first.id)
  end

  test "guests cannot read operations; owner query parameters cannot switch ownership", %{
    owner: owner
  } do
    _job = job(owner, "completed")
    other = AuthTestSupport.authenticated_identity!()
    assert build_conn() |> get("/api/v1/operations") |> json_response(401)

    body =
      other
      |> conn_for()
      |> get("/api/v1/operations?user_id=#{owner.user["user_id"]}")
      |> json_response(200)

    assert body["jobs"] == []
    assert Enum.sum(Map.values(body["counts"])) == 0
  end

  test "limits are explicit bounded numbers", %{owner: owner} do
    for query <- ["limit=0", "limit=101", "limit=-1", "limit=abc", "limit[]=1"] do
      assert owner |> conn_for() |> get("/api/v1/operations?" <> query) |> json_response(422) ==
               %{"error" => "invalid_limit"}
    end
  end

  test "internal metric replay is immutable and never changes a job", %{owner: owner} do
    job = job(owner, "processing")
    body = metric(job)
    first = post_metric(job, body) |> json_response(201) |> Map.fetch!("metric")
    assert first["duration_ms"] == 123.5
    assert first["generated_tokens"] == 12
    assert first["queue_ms"] == nil
    assert first["role"] == "jira-specialist"
    assert first["event_id"] == body["event_id"]
    refute Map.has_key?(first, "user_id")
    assert post_metric(job, body) |> json_response(200) |> Map.fetch!("metric") == first

    assert post_metric(job, %{body | "duration_ms" => 124}) |> json_response(409) == %{
             "error" => "metric_conflict"
           }

    assert {:ok, ^job} = Jobs.get(job.id)
    snapshot = owner |> conn_for() |> get("/api/v1/operations") |> json_response(200)
    assert [row] = snapshot["jobs"]
    assert row["metrics"] == [first]
  end

  test "each job and attempt has its own event identity and only current attempt is shown", %{
    owner: owner
  } do
    first = job(owner, "processing")
    second = job(owner, "processing")
    event = metric(first)
    assert post_metric(first, event) |> json_response(201)
    assert post_metric(second, event) |> json_response(201)
    {:ok, current} = Jobs.update(%{first | attempts: 2})
    assert post_metric(first, event) |> json_response(409) == %{"error" => "stale_attempt"}

    assert post_metric(current, %{event | "attempt" => 2, "generated_tokens" => 7})
           |> json_response(201)

    body = owner |> conn_for() |> get("/api/v1/operations") |> json_response(200)
    row = Enum.find(body["jobs"], &(&1["job_id"] == first.id))
    assert [%{"attempt" => 2, "generated_tokens" => 7}] = row["metrics"]
  end

  test "tail measurements are accepted after approval and completion without rewriting outcomes",
       %{owner: owner} do
    for status <- ["waiting_approval", "completed", "failed", "outcome_unknown"] do
      job = job(owner, status)
      assert post_metric(job, metric(job)) |> json_response(201)
      assert {:ok, ^job} = Jobs.get(job.id)
    end
  end

  test "only the internal credential admits observations", %{owner: owner} do
    job = job(owner, "processing")

    for conn <- [
          build_conn(),
          conn_for(owner),
          build_conn() |> put_req_header("x-internal-token", "wrong")
        ] do
      assert conn |> post(path(job), metric(job)) |> json_response(401) == %{
               "error" => "unauthorized"
             }
    end

    assert post_metric(%{job | id: String.duplicate("0", 32)}, metric(job)) |> json_response(404) ==
             %{"error" => "job_not_found"}

    assert post_metric(job, Map.put(metric(job), "attempt", 2)) |> json_response(409) == %{
             "error" => "stale_attempt"
           }
  end

  test "unknown or invalid metric values never become observations", %{owner: owner} do
    job = job(owner, "processing")
    base = metric(job)

    bad = [
      Map.delete(base, "stage"),
      Map.put(base, "prompt", "private secret"),
      %{base | "attempt" => true},
      %{base | "event_id" => "not-an-id"},
      %{base | "stage" => "secret content"},
      %{base | "adapter" => "mock"},
      %{base | "outcome" => "completed"},
      %{base | "duration_ms" => -1},
      Map.put(base, "generated_tokens", 1.5),
      Map.put(base, "queue_ms", true),
      Map.put(base, "role", "Private USER"),
      Map.put(base, "repair_of", "unknown")
    ]

    for input <- bad do
      assert post_metric(job, input) |> json_response(422) == %{"error" => "invalid_metric"}
    end

    body = owner |> conn_for() |> get("/api/v1/operations") |> json_response(200)
    assert [%{"metrics" => []}] = body["jobs"]
  end

  test "missing times and measurements stay unknown", %{owner: owner} do
    queued = job(owner, "pending")
    body = owner |> conn_for() |> get("/api/v1/operations") |> json_response(200)
    assert [%{"queue_wait_ms" => nil, "metrics" => [], "attempt" => 0}] = body["jobs"]
    assert {:ok, ^queued} = Jobs.get(queued.id)
  end

  test "a selected user model keeps its actual adapter and unavailable counters", %{owner: owner} do
    job = job(owner, "processing")
    body = metric(job) |> Map.put("adapter", "hf-causal") |> Map.delete("generated_tokens")

    assert %{"metric" => %{"adapter" => "hf-causal", "generated_tokens" => nil}} =
             post_metric(job, body) |> json_response(201)
  end

  test "metric histories are bounded and disclose truncation", %{owner: owner} do
    job = job(owner, "processing")

    rows =
      Enum.map(1..65, fn index ->
        input = metric(job) |> Map.put("event_id", Base.encode16(<<index::128>>, case: :lower))

        Map.merge(input, %{
          "job_id" => job.id,
          "user_id" => job.user_id,
          "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })
      end)

    assert {:ok, _} = Surreal.query("INSERT INTO job_metric $rows;", %{"rows" => rows})
    body = owner |> conn_for() |> get("/api/v1/operations") |> json_response(200)
    assert [row] = body["jobs"]
    assert row["metrics_truncated"] == true
    assert length(row["metrics"]) == 64
  end

  test "concurrent copies retain one immutable observation", %{owner: owner} do
    job = job(owner, "processing")
    input = metric(job)

    responses =
      1..8
      |> Task.async_stream(fn _ -> post_metric(job, input) end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, conn} -> {conn.status, Jason.decode!(conn.resp_body)} end)

    assert Enum.count(responses, fn {status, _} -> status == 201 end) == 1
    assert Enum.all?(responses, fn {status, _} -> status in [200, 201] end)

    assert responses |> Enum.map(fn {_, body} -> body["metric"] end) |> Enum.uniq() |> length() ==
             1

    snapshot = owner |> conn_for() |> get("/api/v1/operations") |> json_response(200)
    assert [%{"metrics" => [_one]}] = snapshot["jobs"]
  end

  test "an acknowledgement lost after persistence needs exact readback, not another event", %{
    owner: owner
  } do
    job = job(owner, "processing")
    input = metric(job)
    restore = StorageFaultProxy.install!(:lost_response, ~r/BEGIN TRANSACTION/)
    response = post_metric(job, input) |> json_response(200)
    assert_received {:storage_fault, :lost_response}
    assert response["metric"]["event_id"] == input["event_id"]
    restore.()
    assert post_metric(job, input) |> json_response(200) == response
    assert {:ok, ^job} = Jobs.get(job.id)
  end

  test "unconfirmed persistence and unavailable reads never become healthy zeroes", %{
    owner: owner
  } do
    job = job(owner, "processing")
    restore = StorageFaultProxy.install!(:empty_result, ~r/BEGIN TRANSACTION/)

    assert post_metric(job, metric(job)) |> json_response(503) == %{
             "error" => "metric_outcome_unknown"
           }

    assert_received {:storage_fault, :empty_result}
    restore.()
    restore_read = StorageFaultProxy.install!(:rpc_error, ~r/SELECT status, count\(\)/)
    response = owner |> conn_for() |> get("/api/v1/operations") |> json_response(503)
    assert response["error"] == "operations_unavailable"
    refute Map.has_key?(response, "counts")
    assert_received {:storage_fault, :rpc_error}
    restore_read.()
    assert {:ok, ^job} = Jobs.get(job.id)
  end

  defp metric(job) do
    %{
      "attempt" => job.attempts,
      "event_id" => :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
      "stage" => "SPECIALIST_REASONING",
      "operation" => "generate",
      "adapter" => "local",
      "outcome" => "success",
      "duration_ms" => 123.5,
      "role" => "jira-specialist",
      "generated_tokens" => 12
    }
  end

  defp job(identity, status) do
    {:ok, job} =
      Jobs.create(%{
        user_id: identity.user["user_id"],
        conversation_id: identity.chat["chat_id"],
        message: "private request"
      })

    if status == "pending" do
      job
    else
      {:ok, claimed} = Job.claim(job, 60)

      candidate =
        if status == "processing", do: claimed, else: elem(Job.transition(claimed, status), 1)

      {:ok, stored} =
        Jobs.update(Job.put_ai_metadata(candidate, selected_agent: "jira-specialist"))

      stored
    end
  end

  defp path(job), do: "/api/internal/v1/jobs/#{job.id}/metrics"

  defp post_metric(job, body),
    do: build_conn() |> put_req_header("x-internal-token", @token) |> post(path(job), body)

  defp conn_for(identity),
    do: build_conn() |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
end
