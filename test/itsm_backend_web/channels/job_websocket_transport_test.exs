defmodule ItsmBackendWeb.JobWebsocketTransportTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias ItsmBackend.{Auth, Jobs, RuntimeConfig}
  alias ItsmBackend.Jobs.Job
  alias ItsmBackendWeb.{AuthTestSupport, Endpoint, SocketAuth}

  setup do
    server =
      start_supervised!({Bandit, plug: Endpoint, port: 0, ip: {127, 0, 0, 1}, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    identity = AuthTestSupport.authenticated_identity!()

    {:ok, job} =
      Jobs.create(%{
        user_id: identity.user["user_id"],
        conversation_id: identity.chat["chat_id"],
        message: "transport test request"
      })

    %{port: port, identity: identity, job: job}
  end

  test "real HTTP ticket upgrades, joins, and delivers persisted changes without result bodies",
       ctx do
    response =
      Req.post!(
        "http://127.0.0.1:#{ctx.port}/api/v2/jobs/socket-token",
        headers: [{"authorization", "Bearer " <> ctx.identity.auth.raw_token}],
        json: %{},
        retry: false
      )

    assert response.status == 200
    assert response.body["expires_in"] == 120
    assert response.headers["cache-control"] == ["no-store"]

    {socket, status, headers} = upgrade(ctx.port, response.body["token"])
    assert status == "HTTP/1.1 101 Switching Protocols"
    assert headers["sec-websocket-protocol"] == "phoenix"
    topic = "job:#{ctx.job.id}"

    send_frame(socket, ["1", "1", topic, "phx_join", %{}])
    assert ["1", "1", ^topic, "phx_reply", reply] = receive_frame(socket)

    assert reply == %{
             "status" => "ok",
             "response" => %{"job_id" => ctx.job.id, "status" => "pending", "attempts" => 0}
           }

    send_frame(socket, [nil, "2", "phoenix", "heartbeat", %{}])
    assert [nil, "2", "phoenix", "phx_reply", %{"status" => "ok"}] = receive_frame(socket)

    {:ok, processing} = Job.claim(ctx.job, 300)
    assert {:ok, _} = Jobs.update(processing)
    assert ["1", nil, ^topic, "job_updated", update] = receive_frame(socket)

    assert update == %{
             "job_id" => ctx.job.id,
             "status" => "processing",
             "attempts" => 1
           }

    {ai_socket, ai_status, _headers} =
      upgrade(ctx.port, nil,
        path: "/ai_socket/websocket?vsn=2.0.0",
        origin: "http://localhost",
        extra_headers: [{"X-Internal-Token", RuntimeConfig.internal_job_token!()}]
      )

    assert ai_status == "HTTP/1.1 101 Switching Protocols"
    ai_topic = "ai_jobs:#{ctx.job.id}"
    send_frame(ai_socket, ["1", "1", ai_topic, "phx_join", %{"attempt" => 1}])

    assert ["1", "1", ^ai_topic, "phx_reply", %{"status" => "ok"}] =
             receive_frame(ai_socket)

    send_frame(ai_socket, ["1", "2", ai_topic, "progress", %{"stage" => "routing"}])

    assert ["1", "2", ^ai_topic, "phx_reply", %{"status" => "ok"}] =
             receive_frame(ai_socket)

    assert ["1", nil, ^topic, "job_progress", progress] = receive_frame(socket)

    assert progress == %{"job_id" => ctx.job.id, "attempt" => 1, "stage" => "routing"}

    send_frame(socket, ["1", "3", topic, "approve", %{}])

    assert [
             "1",
             "3",
             ^topic,
             "phx_reply",
             %{
               "status" => "error",
               "response" => %{"reason" => "read_only"}
             }
           ] = receive_frame(socket)

    assert {:ok, %{status: "processing", result: nil}} = Jobs.get(ctx.job.id)

    assert {:ok, _, :applied} =
             Jobs.apply_completion(ctx.job.id, 1, "completed", %{
               "result" => %{"answer" => "transport-private-result"}
             })

    assert ["1", nil, ^topic, "job_updated", completion] = receive_frame(socket)

    assert completion == %{
             "job_id" => ctx.job.id,
             "status" => "completed",
             "attempts" => 1
           }

    assert {:ok, %{status: "completed"}} = Jobs.get(ctx.job.id)
  end

  @tag capture_log: true
  test "real upgrades reject URL credentials, tampered tickets and untrusted origins", ctx do
    ticket = SocketAuth.issue(ctx.identity.user, ctx.identity.auth.session)

    for opts <- [
          [token: nil, path: "/socket/websocket?vsn=2.0.0&token=#{ticket.token}"],
          [token: "tampered"],
          [token: ticket.token, origin: "https://untrusted.example.test"]
        ] do
      {_socket, status, _headers} = upgrade(ctx.port, opts[:token], opts)
      assert status == "HTTP/1.1 403 Forbidden"
    end
  end

  test "real transport retains owner authorization and refuses revoked sessions", ctx do
    other = AuthTestSupport.authenticated_identity!()
    ticket = SocketAuth.issue(other.user, other.auth.session)
    {socket, status, _headers} = upgrade(ctx.port, ticket.token)
    assert status == "HTTP/1.1 101 Switching Protocols"
    topic = "job:#{ctx.job.id}"
    send_frame(socket, ["1", "1", topic, "phx_join", %{}])

    assert [
             "1",
             "1",
             ^topic,
             "phx_reply",
             %{
               "status" => "error",
               "response" => %{"reason" => "unauthorized"}
             }
           ] = receive_frame(socket)

    assert {:ok, _} = Auth.revoke_session(other.user["user_id"], other.auth.session["session_id"])
    {_socket, revoked_status, _headers} = upgrade(ctx.port, ticket.token)
    assert revoked_status == "HTTP/1.1 403 Forbidden"
  end

  # A tiny RFC 6455 test client exercises the real HTTP Upgrade and Phoenix
  # transport boundary without replacing either side or adding a dependency.
  defp upgrade(port, token, opts \\ []) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :line], 5_000)

    on_exit(fn -> :gen_tcp.close(socket) end)
    path = Keyword.get(opts, :path, "/socket/websocket?vsn=2.0.0")
    origin = Keyword.get(opts, :origin, "http://127.0.0.1:8080")

    protocol =
      if token do
        "Sec-WebSocket-Protocol: phoenix, base64url.bearer.phx." <>
          Base.encode64(token, padding: false) <> "\r\n"
      else
        "Sec-WebSocket-Protocol: phoenix\r\n"
      end

    :ok =
      :gen_tcp.send(socket, [
        "GET ",
        path,
        " HTTP/1.1\r\nHost: 127.0.0.1:",
        Integer.to_string(port),
        "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ",
        Base.encode64(:crypto.strong_rand_bytes(16)),
        "\r\nOrigin: ",
        origin,
        "\r\n",
        protocol,
        Enum.map(Keyword.get(opts, :extra_headers, []), fn {name, value} ->
          [name, ": ", value, "\r\n"]
        end),
        "\r\n"
      ])

    {:ok, status} = :gen_tcp.recv(socket, 0, 5_000)
    headers = receive_headers(socket, %{})
    :ok = :inet.setopts(socket, packet: :raw)
    {socket, String.trim(status), headers}
  end

  defp receive_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "\r\n"} ->
        headers

      {:ok, line} ->
        [name, value] = String.split(line, ":", parts: 2)
        receive_headers(socket, Map.put(headers, String.downcase(name), String.trim(value)))
    end
  end

  defp send_frame(socket, frame) do
    payload = Jason.encode!(frame)
    mask = :crypto.strong_rand_bytes(4)

    masked =
      payload
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {byte, index} -> bxor(byte, :binary.at(mask, rem(index, 4))) end)
      |> :erlang.list_to_binary()

    size = byte_size(payload)
    length = if size < 126, do: <<1::1, size::7>>, else: <<1::1, 126::7, size::16>>
    :ok = :gen_tcp.send(socket, [<<1::1, 0::3, 1::4>>, length, mask, masked])
  end

  defp receive_frame(socket) do
    {:ok, <<1::1, 0::3, 1::4, 0::1, length::7>>} = :gen_tcp.recv(socket, 2, 5_000)

    size =
      case length do
        126 ->
          {:ok, <<size::16>>} = :gen_tcp.recv(socket, 2, 5_000)
          size

        size ->
          size
      end

    {:ok, payload} = :gen_tcp.recv(socket, size, 5_000)
    Jason.decode!(payload)
  end
end
