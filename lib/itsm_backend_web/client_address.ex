defmodule ItsmBackendWeb.ClientAddress do
  @moduledoc """
  The client's address for per-client limits, behind a trusted reverse proxy.

  Behind the deployment's proxy every request reaches Phoenix from the proxy's
  address, so `X-Forwarded-For` is read, but only when the immediate peer is a
  configured trusted proxy (`TRUSTED_PROXIES`, CIDR ranges). Each proxy appends
  the address it received from, so the rightmost entry that is not itself a
  trusted proxy is the client; entries to its left are whatever the client chose
  to send and are ignored. Without trusted proxies nothing is rewritten.
  """

  @behaviour Plug

  import Bitwise

  alias ItsmBackend.RuntimeConfig

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    trusted = RuntimeConfig.trusted_proxies!()

    if trusted != [] and trusted?(conn.remote_ip, trusted) do
      %{conn | remote_ip: forwarded_client(conn, trusted)}
    else
      conn
    end
  end

  defp forwarded_client(conn, trusted) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reverse()
    |> Enum.reduce_while(conn.remote_ip, fn entry, proxy ->
      case :inet.parse_strict_address(String.to_charlist(entry)) do
        {:ok, address} ->
          if trusted?(address, trusted), do: {:cont, address}, else: {:halt, address}

        # A malformed hop cannot be attributed; keep the last trusted address.
        {:error, _} ->
          {:halt, proxy}
      end
    end)
  end

  defp trusted?(address, ranges), do: Enum.any?(ranges, &within?(address, &1))

  defp within?(address, {network, bits}) when tuple_size(address) == tuple_size(network) do
    width = if tuple_size(address) == 4, do: 32, else: 128
    shift = width - bits
    integer(address) >>> shift == integer(network) >>> shift
  end

  defp within?(_address, _range), do: false

  defp integer({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp integer(address) when tuple_size(address) == 8 do
    address |> Tuple.to_list() |> Enum.reduce(0, fn part, total -> (total <<< 16) + part end)
  end
end
