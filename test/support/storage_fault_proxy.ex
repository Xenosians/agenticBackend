defmodule ItsmBackendWeb.StorageFaultProxy do
  @moduledoc """
  A SurrealDB stand-in for tests.

  Every request is forwarded to the real test database, except RPC queries
  whose statement matches `fail_when`. Those receive the configured fault, so
  a test can break one storage call while the calls around it still work.

    * `:http_500` - fail without running the statement
    * `:rpc_error` - answer with a JSON-RPC error without running the statement
    * `:empty_result` - answer as if nothing matched, without running the statement
    * `:lost_response` - run the statement, then lose the answer (HTTP 502)
    * `:duplicate_rows` - run the statement, then return every row twice (an index
      read during concurrent conflicting writes was once seen doing this)

  The test process receives `{:storage_fault, fault}` for every injected fault.
  """

  import Plug.Conn

  @forwarded_headers ~w(accept authorization content-type surreal-ns surreal-db)

  @doc "Routes storage through the proxy. Returns a function that restores direct access."
  def install!(fault, %Regex{} = fail_when)
      when fault in [:http_500, :rpc_error, :empty_result, :lost_response, :duplicate_rows] do
    original = Application.fetch_env!(:itsm_backend, :surrealdb)

    options = %{
      upstream: Keyword.fetch!(original, :url),
      fault: fault,
      fail_when: fail_when,
      test: self()
    }

    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {__MODULE__, options}, port: 0, ip: {127, 0, 0, 1}},
        id: {__MODULE__, make_ref()}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Application.put_env(
      :itsm_backend,
      :surrealdb,
      Keyword.put(original, :url, "http://127.0.0.1:#{port}")
    )

    restore = fn -> Application.put_env(:itsm_backend, :surrealdb, original) end
    ExUnit.Callbacks.on_exit(restore)
    restore
  end

  def init(options), do: options

  def call(conn, options) do
    {:ok, body, conn} = read_body(conn)

    case fault_target(conn, body, options.fail_when) do
      {:ok, request_id} ->
        send(options.test, {:storage_fault, options.fault})
        inject(conn, body, request_id, options)

      :pass ->
        relay(conn, body, options.upstream)
    end
  end

  defp fault_target(%{request_path: "/rpc"}, body, pattern) do
    case Jason.decode(body) do
      {:ok, %{"id" => id, "params" => [statement | _]}} when is_binary(statement) ->
        if Regex.match?(pattern, statement), do: {:ok, id}, else: :pass

      _ ->
        :pass
    end
  end

  defp fault_target(_conn, _body, _pattern), do: :pass

  defp inject(conn, _body, _id, %{fault: :http_500}),
    do: send_resp(conn, 500, "injected storage failure")

  defp inject(conn, _body, id, %{fault: :rpc_error}),
    do: json(conn, %{"id" => id, "error" => %{"code" => -32_000, "message" => "injected"}})

  defp inject(conn, _body, id, %{fault: :empty_result}),
    do: json(conn, %{"id" => id, "result" => [%{"status" => "OK", "result" => nil}]})

  defp inject(conn, body, _id, %{fault: :lost_response, upstream: upstream}) do
    _ = forward(conn, body, upstream)
    send_resp(conn, 502, "the statement ran but its answer was lost")
  end

  defp inject(conn, body, _id, %{fault: :duplicate_rows, upstream: upstream}) do
    with {:ok, %{status: 200, body: raw}} <- forward(conn, body, upstream),
         {:ok, %{"result" => statements} = reply} when is_list(statements) <- Jason.decode(raw) do
      doubled =
        Enum.map(statements, fn
          %{"result" => rows} = statement when is_list(rows) ->
            %{statement | "result" => Enum.flat_map(rows, &[&1, &1])}

          statement ->
            statement
        end)

      json(conn, %{reply | "result" => doubled})
    else
      _ -> send_resp(conn, 502, "storage upstream unavailable")
    end
  end

  defp relay(conn, body, upstream) do
    case forward(conn, body, upstream) do
      {:ok, response} ->
        conn
        |> put_resp_header("content-type", content_type(response))
        |> send_resp(response.status, response.body)

      {:error, _reason} ->
        send_resp(conn, 502, "storage upstream unavailable")
    end
  end

  defp forward(conn, body, upstream) do
    headers = for {name, value} <- conn.req_headers, name in @forwarded_headers, do: {name, value}

    Req.request(
      method: conn.method |> String.downcase() |> String.to_existing_atom(),
      url: upstream <> conn.request_path,
      headers: headers,
      body: body,
      decode_body: false,
      retry: false
    )
  end

  defp content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _] -> value
      [] -> "application/octet-stream"
    end
  end

  defp json(conn, payload) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(payload))
  end
end
