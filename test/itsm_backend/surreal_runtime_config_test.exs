defmodule ItsmBackend.SurrealRuntimeConfigTest do
  use ExUnit.Case,
    async: false

  alias ItsmBackend.RuntimeConfig

  setup do
    original =
      Application.get_env(
        :itsm_backend,
        :surrealdb
      )

    on_exit(fn ->
      restore_config(original)
    end)

    :ok
  end

  test "returns validated SurrealDB configuration" do
    Application.put_env(
      :itsm_backend,
      :surrealdb,
      url: "http://127.0.0.1:9001/",
      namespace: "itsm",
      database: "itsm",
      username: "test_user",
      password: "test_password"
    )

    assert RuntimeConfig.surrealdb!() ==
             %{
               url: "http://127.0.0.1:9001",
               namespace: "itsm",
               database: "itsm",
               username: "test_user",
               password: "test_password"
             }
  end

  test "rejects invalid SurrealDB URL" do
    put_valid_config(url: "file:///tmp/surreal")

    assert_raise RuntimeConfig.Error,
                 ~r/surrealdb.url/,
                 fn ->
                   RuntimeConfig.surrealdb!()
                 end
  end

  test "rejects blank SurrealDB namespace" do
    put_valid_config(namespace: "   ")

    assert_raise RuntimeConfig.Error,
                 ~r/surrealdb.namespace/,
                 fn ->
                   RuntimeConfig.surrealdb!()
                 end
  end

  test "rejects missing SurrealDB password" do
    Application.put_env(
      :itsm_backend,
      :surrealdb,
      url: "http://127.0.0.1:9001",
      namespace: "itsm",
      database: "itsm",
      username: "test_user"
    )

    assert_raise RuntimeConfig.Error,
                 ~r/surrealdb.password/,
                 fn ->
                   RuntimeConfig.surrealdb!()
                 end
  end

  test "rejects blank SurrealDB password" do
    put_valid_config(password: "   ")

    assert_raise RuntimeConfig.Error,
                 ~r/surrealdb.password/,
                 fn ->
                   RuntimeConfig.surrealdb!()
                 end
  end

  defp put_valid_config(overrides) do
    config =
      [
        url: "http://127.0.0.1:9001",
        namespace: "itsm",
        database: "itsm",
        username: "test_user",
        password: "test_password"
      ]
      |> Keyword.merge(overrides)

    Application.put_env(
      :itsm_backend,
      :surrealdb,
      config
    )
  end

  defp restore_config(nil) do
    Application.delete_env(
      :itsm_backend,
      :surrealdb
    )
  end

  defp restore_config(config) do
    Application.put_env(
      :itsm_backend,
      :surrealdb,
      config
    )
  end
end
