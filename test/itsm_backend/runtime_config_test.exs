defmodule ItsmBackend.RuntimeConfigTest do
  use ExUnit.Case,
    async: false

  alias ItsmBackend.RuntimeConfig

  setup do
    original_queue_worker =
      Application.get_env(
        :itsm_backend,
        :queue_worker
      )

    original_ai_service =
      Application.get_env(
        :itsm_backend,
        :ai_service
      )

    on_exit(fn ->
      restore_config(
        :queue_worker,
        original_queue_worker
      )

      restore_config(
        :ai_service,
        original_ai_service
      )
    end)

    :ok
  end

  # ------------------------------------------------------------
  # Queue worker
  # ------------------------------------------------------------

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

  # ------------------------------------------------------------
  # AI service
  # ------------------------------------------------------------

  test "returns validated AI service configuration" do
    Application.put_env(
      :itsm_backend,
      :ai_service,
      base_url: "http://127.0.0.1:9000/",
      run_timeout_ms: 120_000,
      execute_timeout_ms: 8_000,
      health_timeout_ms: 2_000,
      ready_timeout_ms: 3_000
    )

    assert RuntimeConfig.ai_service!() ==
             %{
               base_url: "http://127.0.0.1:9000",
               run_timeout_ms: 120_000,
               execute_timeout_ms: 8_000,
               health_timeout_ms: 2_000,
               ready_timeout_ms: 3_000
             }
  end

  test "rejects invalid AI service URL scheme" do
    put_valid_ai_service(base_url: "ftp://127.0.0.1:9000")

    assert_raise RuntimeConfig.Error,
                 ~r/base_url/,
                 fn ->
                   RuntimeConfig.ai_service!()
                 end
  end

  test "rejects blank AI service URL" do
    put_valid_ai_service(base_url: " ")

    assert_raise RuntimeConfig.Error,
                 ~r/base_url/,
                 fn ->
                   RuntimeConfig.ai_service!()
                 end
  end

  test "rejects missing AI timeout" do
    Application.put_env(
      :itsm_backend,
      :ai_service,
      base_url: "http://127.0.0.1:9000",
      run_timeout_ms: 120_000,
      execute_timeout_ms: 8_000,
      health_timeout_ms: 2_000
    )

    assert_raise RuntimeConfig.Error,
                 ~r/ready_timeout_ms/,
                 fn ->
                   RuntimeConfig.ai_service!()
                 end
  end

  test "rejects non-positive AI timeout" do
    put_valid_ai_service(execute_timeout_ms: 0)

    assert_raise RuntimeConfig.Error,
                 ~r/execute_timeout_ms/,
                 fn ->
                   RuntimeConfig.ai_service!()
                 end
  end

  # ------------------------------------------------------------
  # Test helpers
  # ------------------------------------------------------------

  defp put_valid_ai_service(overrides) do
    config =
      [
        base_url: "http://127.0.0.1:9000",
        run_timeout_ms: 120_000,
        execute_timeout_ms: 8_000,
        health_timeout_ms: 2_000,
        ready_timeout_ms: 3_000
      ]
      |> Keyword.merge(overrides)

    Application.put_env(
      :itsm_backend,
      :ai_service,
      config
    )
  end

  defp restore_config(
         key,
         nil
       ) do
    Application.delete_env(
      :itsm_backend,
      key
    )
  end

  defp restore_config(
         key,
         value
       ) do
    Application.put_env(
      :itsm_backend,
      key,
      value
    )
  end
end
