defmodule ItsmBackend.DNSClusterRuntimeConfigTest do
  use ExUnit.Case,
    async: false

  alias ItsmBackend.RuntimeConfig

  setup do
    original =
      Application.get_env(
        :itsm_backend,
        :dns_cluster_query
      )

    on_exit(fn ->
      restore_config(original)
    end)

    :ok
  end

  test "disables DNS clustering when configuration is absent" do
    Application.delete_env(
      :itsm_backend,
      :dns_cluster_query
    )

    assert RuntimeConfig.dns_cluster_query!() ==
             :ignore
  end

  test "disables DNS clustering when configuration is nil" do
    Application.put_env(
      :itsm_backend,
      :dns_cluster_query,
      nil
    )

    assert RuntimeConfig.dns_cluster_query!() ==
             :ignore
  end

  test "returns normalized DNS cluster query" do
    Application.put_env(
      :itsm_backend,
      :dns_cluster_query,
      "  app.internal.example  "
    )

    assert RuntimeConfig.dns_cluster_query!() ==
             "app.internal.example"
  end

  test "rejects blank DNS cluster query" do
    Application.put_env(
      :itsm_backend,
      :dns_cluster_query,
      "   "
    )

    assert_raise RuntimeConfig.Error,
                 ~r/non-empty string/,
                 fn ->
                   RuntimeConfig.dns_cluster_query!()
                 end
  end

  test "rejects non-string DNS cluster query" do
    Application.put_env(
      :itsm_backend,
      :dns_cluster_query,
      123
    )

    assert_raise RuntimeConfig.Error,
                 ~r/string or nil/,
                 fn ->
                   RuntimeConfig.dns_cluster_query!()
                 end
  end

  defp restore_config(nil) do
    Application.delete_env(
      :itsm_backend,
      :dns_cluster_query
    )
  end

  defp restore_config(value) do
    Application.put_env(
      :itsm_backend,
      :dns_cluster_query,
      value
    )
  end
end
