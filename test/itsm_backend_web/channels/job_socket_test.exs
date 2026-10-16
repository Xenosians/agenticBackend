defmodule ItsmBackendWeb.JobSocketTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias ItsmBackend.{Auth, Jobs, RuntimeConfig}
  alias ItsmBackend.Jobs.{Events, Job}
  alias ItsmBackendWeb.{AuthTestSupport, InternalJobSocket, JobChannel, JobProgressChannel}
  alias ItsmBackendWeb.{SocketAuth, UserSocket}

  @endpoint ItsmBackendWeb.Endpoint

  setup do
    identity = AuthTestSupport.authenticated_identity!()

    {:ok, job} =
      Jobs.create(%{
        user_id: identity.user["user_id"],
        conversation_id: identity.chat["chat_id"],
        message: "private request body"
      })

    %{identity: identity, job: job}
  end

  test "socket requires signed header ticket, never a URL parameter", %{identity: id} do
    ticket = SocketAuth.issue(id.user, id.auth.session)
    assert {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: ticket.token})
    assert socket.assigns.user_id == id.user["user_id"]
    assert :error = connect(UserSocket, %{"token" => ticket.token})
    assert :error = connect(UserSocket, %{}, connect_info: %{auth_token: "tampered"})

    expired =
      Phoenix.Token.sign(
        @endpoint,
        "job-status-socket-v1",
        {id.user["user_id"], id.auth.session["session_id"]},
        signed_at: System.system_time(:second) - 121
      )

    assert :error = connect(UserSocket, %{}, connect_info: %{auth_token: expired})
  end

  test "revoked session cannot connect with an otherwise valid ticket", %{identity: id} do
    ticket = SocketAuth.issue(id.user, id.auth.session)
    assert {:ok, _} = Auth.revoke_session(id.user["user_id"], id.auth.session["session_id"])
    assert :error = connect(UserSocket, %{}, connect_info: %{auth_token: ticket.token})
  end

  test "only an authorized owner can subscribe and join returns latest persisted summary", ctx do
    {:ok, processing} = Job.claim(ctx.job, 300)
    {:ok, _} = Jobs.update(processing)
    socket = user_socket(ctx.identity)

    assert {:ok, %{job_id: job_id, status: "processing", attempts: 1}, _joined} =
             subscribe_and_join(socket, JobChannel, "job:#{ctx.job.id}")

    assert job_id == ctx.job.id
    other = AuthTestSupport.authenticated_identity!()

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(user_socket(other), JobChannel, "job:#{ctx.job.id}")

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, JobChannel, "job:#{String.duplicate("0", 32)}")

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, JobChannel, "job:invalid")
  end

  test "persisted completion pushes a bounded invalidation, duplicate callback pushes nothing",
       ctx do
    {:ok, processing} = Job.claim(ctx.job, 300)
    {:ok, _} = Jobs.update(processing)

    {:ok, _reply, _socket} =
      subscribe_and_join(user_socket(ctx.identity), JobChannel, "job:#{ctx.job.id}")

    assert {:ok, stored, :applied} =
             Jobs.apply_completion(ctx.job.id, 1, "completed", %{
               "result" => %{"answer" => "private model answer", "password" => "private fixture"}
             })

    assert_push "job_updated", payload, 1_000
    assert payload == %{job_id: stored.id, status: "completed", attempts: 1}
    assert {:ok, persisted} = Jobs.get(stored.id)
    assert persisted.status == payload.status
    refute Map.has_key?(payload, :result)
    refute Map.has_key?(payload, :message)

    assert {:ok, _, :duplicate} = Jobs.apply_completion(ctx.job.id, 1, "completed", %{})
    refute_push "job_updated", _
  end

  test "approval resolution uses v2 status and is durable before the update event", ctx do
    {:ok, processing} = Job.claim(ctx.job, 300)
    {:ok, _} = Jobs.update(processing)
    {:ok, waiting} = Job.transition(processing, "waiting_approval")
    {:ok, _} = Jobs.update(waiting)

    {:ok, _reply, _socket} =
      subscribe_and_join(user_socket(ctx.identity), JobChannel, "job:#{ctx.job.id}")

    {:ok, rejected} = Job.transition(waiting, "denied")
    assert {:ok, stored} = Jobs.complete_approval(rejected)
    assert_push "job_updated", %{job_id: job_id, status: "denied", attempts: 1}, 1_000
    assert job_id == stored.id
    assert {:ok, %{status: "denied"}} = Jobs.get(job_id)
  end

  test "revocation stops an established subscription before exposing another update", ctx do
    {:ok, _reply, socket} =
      subscribe_and_join(user_socket(ctx.identity), JobChannel, "job:#{ctx.job.id}")

    monitor = Process.monitor(socket.channel_pid)

    assert {:ok, _} =
             Auth.revoke_session(
               ctx.identity.user["user_id"],
               ctx.identity.auth.session["session_id"]
             )

    {:ok, processing} = Job.claim(ctx.job, 300)
    assert {:ok, _} = Jobs.update(processing)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
    refute_push "job_updated", _
  end

  test "job socket refuses all mutation messages", ctx do
    {:ok, _reply, socket} =
      subscribe_and_join(user_socket(ctx.identity), JobChannel, "job:#{ctx.job.id}")

    ref = push(socket, "approve", %{})
    assert_reply ref, :error, %{reason: "read_only"}
    assert {:ok, %{status: "pending"}} = Jobs.get(ctx.job.id)
  end

  test "origin allowlist matches scheme, host and port instead of development check_origin false" do
    assert SocketAuth.origin_allowed?(URI.parse("http://127.0.0.1:8080"))
    refute SocketAuth.origin_allowed?(URI.parse("https://127.0.0.1:8080"))
    refute SocketAuth.origin_allowed?(URI.parse("http://127.0.0.1:8081"))
    refute SocketAuth.origin_allowed?(URI.parse("http://127.0.0.1.attacker.test:8080"))
  end

  test "AI socket requires exactly one internal header, never URL credentials" do
    token = RuntimeConfig.internal_job_token!()

    assert {:ok, _socket} =
             connect(InternalJobSocket, %{},
               connect_info: %{x_headers: [{"x-internal-token", token}]}
             )

    assert :error = connect(InternalJobSocket, %{"token" => token})

    assert :error =
             connect(InternalJobSocket, %{},
               connect_info: %{x_headers: [{"x-internal-token", "wrong"}]}
             )

    assert :error =
             connect(InternalJobSocket, %{},
               connect_info: %{
                 x_headers: [{"x-internal-token", token}, {"x-internal-token", token}]
               }
             )
  end

  test "AI progress is a validated hint and cannot finalize, alter the attempt or send arbitrary text",
       ctx do
    {:ok, processing} = Job.claim(ctx.job, 300)
    {:ok, _} = Jobs.update(processing)

    {:ok, _reply, _viewer} =
      subscribe_and_join(user_socket(ctx.identity), JobChannel, "job:#{ctx.job.id}")

    {:ok, _reply, ai} =
      subscribe_and_join(internal_socket(), JobProgressChannel, "ai_jobs:#{ctx.job.id}", %{
        "attempt" => 1
      })

    ref = push(ai, "progress", %{"stage" => "routing"})
    assert_reply ref, :ok, %{accepted: true}
    assert_push "job_progress", %{job_id: job_id, attempt: 1, stage: "routing"}, 1_000
    assert job_id == ctx.job.id

    for {event, payload} <- [
          {"progress", %{"stage" => "completed"}},
          {"progress", %{"stage" => "routing", "password" => "private"}},
          {"progress", %{"stage" => "routing", "attempt" => 2}},
          {"complete", %{"status" => "completed"}}
        ] do
      ref = push(ai, event, payload)
      assert_reply ref, :error, %{reason: "invalid_request"}
    end

    refute_push "job_progress", _
    assert {:ok, %{status: "processing", result: nil}} = Jobs.get(ctx.job.id)
  end

  test "AI progress rejects pending, stale, expired and completed attempts", ctx do
    topic = "ai_jobs:#{ctx.job.id}"

    assert {:error, %{reason: "inactive_attempt"}} =
             subscribe_and_join(internal_socket(), JobProgressChannel, topic, %{"attempt" => 1})

    {:ok, processing} = Job.claim(ctx.job, 300)
    {:ok, _} = Jobs.update(processing)

    assert {:error, %{reason: "inactive_attempt"}} =
             subscribe_and_join(internal_socket(), JobProgressChannel, topic, %{"attempt" => 2})

    {:ok, _reply, ai} =
      subscribe_and_join(internal_socket(), JobProgressChannel, topic, %{"attempt" => 1})

    {:ok, _} = Jobs.update(%{processing | lease_expires_at: DateTime.add(DateTime.utc_now(), -1)})
    ref = push(ai, "progress", %{"stage" => "planning"})
    assert_reply ref, :error, %{reason: "inactive_attempt"}

    {:ok, _} = Jobs.update(%{processing | status: "completed"})
    ref = push(ai, "progress", %{"stage" => "executing"})
    assert_reply ref, :error, %{reason: "inactive_attempt"}
  end

  test "failed writes do not publish fabricated updates" do
    id = String.duplicate("f", 32)
    :ok = Phoenix.PubSub.subscribe(ItsmBackend.PubSub, Events.topic(id))
    assert Events.after_write({:error, :unavailable}) == {:error, :unavailable}
    assert Events.after_write({:ok, nil}) == {:ok, nil}
    refute_received {:job_persisted, ^id}
  end

  defp user_socket(id) do
    ticket = SocketAuth.issue(id.user, id.auth.session)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: ticket.token})
    socket
  end

  defp internal_socket do
    {:ok, socket} =
      connect(InternalJobSocket, %{},
        connect_info: %{x_headers: [{"x-internal-token", RuntimeConfig.internal_job_token!()}]}
      )

    socket
  end
end
