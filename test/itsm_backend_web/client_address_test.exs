defmodule ItsmBackendWeb.ClientAddressTest do
  @moduledoc """
  Behind the deployment's reverse proxy every request reaches Phoenix from the
  proxy's address. The client's address is taken from X-Forwarded-For only when
  the immediate peer is a configured trusted proxy, and then only the rightmost
  entry that is not itself a trusted proxy: earlier entries are whatever the
  client chose to send.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias ItsmBackendWeb.ClientAddress

  setup do
    original = Application.get_env(:itsm_backend, :trusted_proxies)
    Application.put_env(:itsm_backend, :trusted_proxies, ["172.16.0.0/12", "::1/128"])
    on_exit(fn -> Application.put_env(:itsm_backend, :trusted_proxies, original) end)
    :ok
  end

  defp client(peer, forwarded) do
    conn = %{conn(:get, "/api/health") | remote_ip: peer}

    conn =
      if forwarded, do: Plug.Conn.put_req_header(conn, "x-forwarded-for", forwarded), else: conn

    ClientAddress.call(conn, ClientAddress.init([])).remote_ip
  end

  test "a trusted proxy's forwarded client address is used" do
    assert client({172, 18, 0, 5}, "203.0.113.7") == {203, 0, 113, 7}
  end

  test "addresses a client prepends to the header are ignored" do
    assert client({172, 18, 0, 5}, "198.51.100.1, 203.0.113.7") == {203, 0, 113, 7}
  end

  test "chained trusted proxies are skipped from the right" do
    assert client({172, 18, 0, 5}, "198.51.100.1, 203.0.113.7, 172.20.0.9") == {203, 0, 113, 7}
  end

  test "an untrusted peer's header is ignored" do
    assert client({203, 0, 113, 50}, "198.51.100.1") == {203, 0, 113, 50}
  end

  test "a malformed forwarded entry keeps the proxy's own address" do
    assert client({172, 18, 0, 5}, "198.51.100.1, not-an-address") == {172, 18, 0, 5}
  end

  test "IPv6 peers and entries are understood" do
    assert client({0, 0, 0, 0, 0, 0, 0, 1}, "2001:db8::42") == {8193, 3512, 0, 0, 0, 0, 0, 66}
  end

  test "without trusted proxies nothing is rewritten" do
    Application.put_env(:itsm_backend, :trusted_proxies, [])
    assert client({172, 18, 0, 5}, "203.0.113.7") == {172, 18, 0, 5}
  end

  test "an invalid trusted-proxy range is a configuration error" do
    Application.put_env(:itsm_backend, :trusted_proxies, ["172.16.0.0/40"])
    assert_raise ItsmBackend.RuntimeConfig.Error, fn -> client({172, 18, 0, 5}, "203.0.113.7") end
  end
end
