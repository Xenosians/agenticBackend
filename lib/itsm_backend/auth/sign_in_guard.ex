defmodule ItsmBackend.Auth.SignInGuard do
  @moduledoc """
  Slows down password guessing and reset-mail flooding.

  Failed sign-ins are counted per account (the hashed email key, so an address
  without an account is counted the same way and nothing is revealed) and per
  client address. Once either count reaches its limit within the window, sign-in
  is refused before any password is checked, so a guess list that contains the
  right password is still stopped. A successful sign-in clears its account's
  count; a client's count only ages out. Password-reset requests are counted per
  client address; past the limit the request is answered the same way but no
  mail is sent.

  Each decision and its count happen in one serialized step, so concurrent
  guesses cannot slip past a limit. Counts live in this node's memory: they bound
  online guessing, they are not an audit record, and they start empty after a
  restart. Limits come from configuration (the `AUTH_SIGN_IN_*` variables).
  """

  use GenServer

  alias ItsmBackend.RuntimeConfig

  @type refusal :: {:error, {:rate_limited, pos_integer()}}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reserves one sign-in attempt for the account and the client.

  `:ok` means the password may be checked; report the outcome with
  `record_success/1` or `record_failure/2`. A refusal carries the seconds left.
  """
  @spec reserve_sign_in(String.t(), :inet.ip_address()) :: :ok | refusal()
  def reserve_sign_in(account_key, address) do
    GenServer.call(__MODULE__, {:reserve_sign_in, account_key, address})
  end

  @doc "Records one failed sign-in for the account and the client."
  @spec record_failure(String.t(), :inet.ip_address()) :: :ok
  def record_failure(account_key, address) do
    GenServer.call(__MODULE__, {:record_failure, account_key, address})
  end

  @doc "A successful sign-in clears its account's failures; the client's count only ages out."
  @spec record_success(String.t()) :: :ok
  def record_success(account_key) do
    GenServer.call(__MODULE__, {:record_success, account_key})
  end

  @doc "Counts one password-reset request from a client, unless it must wait."
  @spec reserve_reset_request(:inet.ip_address()) :: :ok | refusal()
  def reserve_reset_request(address) do
    GenServer.call(__MODULE__, {:reserve_reset_request, address})
  end

  @doc false
  # Test support: forget every count.
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc false
  # Test support: move every recorded moment `seconds` into the past.
  def age(seconds) when is_integer(seconds) and seconds > 0,
    do: GenServer.call(__MODULE__, {:age, seconds})

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:reserve_sign_in, account_key, address}, _from, counts) do
    config = RuntimeConfig.sign_in_guard!()
    now = now()

    seconds =
      max(
        wait(counts, {:account, account_key}, config.account_failures, config, now),
        wait(counts, {:address, address}, config.address_failures, config, now)
      )

    {:reply, decision(seconds), counts}
  end

  def handle_call({:record_failure, account_key, address}, _from, counts) do
    config = RuntimeConfig.sign_in_guard!()
    now = now()

    counts =
      counts
      |> count({:account, account_key}, config, now)
      |> count({:address, address}, config, now)

    {:reply, :ok, counts}
  end

  def handle_call({:record_success, account_key}, _from, counts) do
    {:reply, :ok, Map.delete(counts, {:account, account_key})}
  end

  def handle_call({:reserve_reset_request, address}, _from, counts) do
    config = RuntimeConfig.sign_in_guard!()
    now = now()
    key = {:reset, address}

    case wait(counts, key, config.reset_requests, config, now) do
      0 -> {:reply, :ok, count(counts, key, config, now)}
      seconds -> {:reply, decision(seconds), counts}
    end
  end

  def handle_call(:reset, _from, _counts), do: {:reply, :ok, %{}}

  def handle_call({:age, seconds}, _from, counts) do
    {:reply, :ok,
     Map.new(counts, fn {key, moments} -> {key, Enum.map(moments, &(&1 - seconds))} end)}
  end

  @impl true
  def handle_info(:sweep, counts) do
    cutoff = now() - RuntimeConfig.sign_in_guard!().window_seconds

    counts =
      for {key, moments} <- counts,
          recent = Enum.filter(moments, &(&1 > cutoff)),
          recent != [],
          into: %{},
          do: {key, recent}

    schedule_sweep()
    {:noreply, counts}
  end

  defp decision(0), do: :ok
  defp decision(seconds), do: {:error, {:rate_limited, seconds}}

  # Seconds until enough counted moments leave the window, or 0 under the limit.
  defp wait(counts, key, limit, config, now) do
    recent = recent(counts, key, config.window_seconds, now)

    if length(recent) < limit do
      0
    else
      # Newest first: the limit-th newest moment must age out before the next attempt.
      max(Enum.at(recent, limit - 1) + config.window_seconds - now, 1)
    end
  end

  # Newest first, bounded by the largest limit so a flood never grows a key without bound.
  defp count(counts, key, config, now) do
    keep = Enum.max([config.account_failures, config.address_failures, config.reset_requests])
    Map.put(counts, key, Enum.take([now | recent(counts, key, config.window_seconds, now)], keep))
  end

  defp recent(counts, key, window, now) do
    counts |> Map.get(key, []) |> Enum.filter(&(&1 > now - window))
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.minutes(1))
  defp now, do: System.monotonic_time(:second)
end
