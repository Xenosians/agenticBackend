defmodule ItsmBackend.RuntimeConfigTest do
  use ExUnit.Case,
    async: false

  alias ItsmBackend.RuntimeConfig

  setup do
    original =
      Application.get_env(
        :itsm_backend,
        :queue_worker
      )

    on_exit(fn ->
      restore_queue_config(original)
    end)

    :ok
  end

  test "returns validated queue worker configuration" do
    Application.put_env(
      :itsm_backend,
      :queue_worker,
      enabled: true,
      poll_interval_ms: 250,
      lease_seconds: 30
    )

    assert RuntimeConfig.queue_worker!() ==
             %{
               enabled: true,
               poll_interval_ms: 250,
               lease_seconds: 30
             }
  end

  test "accepts disabled queue worker configuration" do
    Application.put_env(
      :itsm_backend,
      :queue_worker,
      enabled: false,
      poll_interval_ms: 250,
      lease_seconds: 30
    )

    assert RuntimeConfig.queue_worker!() ==
             %{
               enabled: false,
               poll_interval_ms: 250,
               lease_seconds: 30
             }
  end

  test "rejects missing queue worker fields" do
    Application.put_env(
      :itsm_backend,
      :queue_worker,
      enabled: true,
      poll_interval_ms: 250
    )

    assert_raise RuntimeConfig.Error,
                 ~r/lease_seconds/,
                 fn ->
                   RuntimeConfig.queue_worker!()
                 end
  end

  test "rejects invalid polling interval" do
    Application.put_env(
      :itsm_backend,
      :queue_worker,
      enabled: true,
      poll_interval_ms: 0,
      lease_seconds: 30
    )

    assert_raise RuntimeConfig.Error,
                 ~r/poll_interval_ms/,
                 fn ->
                   RuntimeConfig.queue_worker!()
                 end
  end

  test "rejects invalid lease duration" do
    Application.put_env(
      :itsm_backend,
      :queue_worker,
      enabled: true,
      poll_interval_ms: 250,
      lease_seconds: -1
    )

    assert_raise RuntimeConfig.Error,
                 ~r/lease_seconds/,
                 fn ->
                   RuntimeConfig.queue_worker!()
                 end
  end

  test "rejects non-boolean enabled value" do
    Application.put_env(
      :itsm_backend,
      :queue_worker,
      enabled: "yes",
      poll_interval_ms: 250,
      lease_seconds: 30
    )

    assert_raise RuntimeConfig.Error,
                 ~r/enabled/,
                 fn ->
                   RuntimeConfig.queue_worker!()
                 end
  end

  defp restore_queue_config(nil) do
    Application.delete_env(
      :itsm_backend,
      :queue_worker
    )
  end

  defp restore_queue_config(config) do
    Application.put_env(
      :itsm_backend,
      :queue_worker,
      config
    )
  end
end
