defmodule ItsmBackend.CORSRuntimeConfigTest do
  use ExUnit.Case,
    async: false

  alias ItsmBackend.RuntimeConfig

  setup do
    original =
      Application.get_env(
        :itsm_backend,
        :cors
      )

    on_exit(fn ->
      restore_config(original)
    end)

    :ok
  end

  test "returns normalized allowed origins" do
    Application.put_env(
      :itsm_backend,
      :cors,
      allowed_origins: [
        " http://frontend.test:8080/ ",
        "https://frontend.example"
      ]
    )

    assert RuntimeConfig.cors_origins!() == [
             "http://frontend.test:8080",
             "https://frontend.example"
           ]
  end

  test "removes duplicate origins" do
    Application.put_env(
      :itsm_backend,
      :cors,
      allowed_origins: [
        "https://frontend.example",
        "https://frontend.example/"
      ]
    )

    assert RuntimeConfig.cors_origins!() == [
             "https://frontend.example"
           ]
  end

  test "rejects wildcard origin" do
    put_origins(["*"])

    assert_raise RuntimeConfig.Error,
                 ~r/HTTP\(S\) origins/,
                 fn ->
                   RuntimeConfig.cors_origins!()
                 end
  end

  test "rejects origin containing a path" do
    put_origins([
      "https://frontend.example/app"
    ])

    assert_raise RuntimeConfig.Error,
                 ~r/without paths/,
                 fn ->
                   RuntimeConfig.cors_origins!()
                 end
  end

  test "rejects empty origin list" do
    put_origins([])

    assert_raise RuntimeConfig.Error,
                 ~r/at least one origin/,
                 fn ->
                   RuntimeConfig.cors_origins!()
                 end
  end

  test "rejects non-string origin" do
    put_origins([
      123
    ])

    assert_raise RuntimeConfig.Error,
                 ~r/entries to be strings/,
                 fn ->
                   RuntimeConfig.cors_origins!()
                 end
  end

  defp put_origins(origins) do
    Application.put_env(
      :itsm_backend,
      :cors,
      allowed_origins: origins
    )
  end

  defp restore_config(nil) do
    Application.delete_env(
      :itsm_backend,
      :cors
    )
  end

  defp restore_config(config) do
    Application.put_env(
      :itsm_backend,
      :cors,
      config
    )
  end
end
