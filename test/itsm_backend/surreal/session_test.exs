defmodule ItsmBackend.Surreal.SessionTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.RuntimeConfig
  alias ItsmBackend.Surreal
  alias ItsmBackend.Surreal.Session

  setup do
    Session.invalidate()
    on_exit(&Session.invalidate/0)
    :ok
  end

  test "queries authenticate with a cached bearer token" do
    config = RuntimeConfig.surrealdb!()

    assert {:bearer, token} = Session.auth(config)
    assert {:bearer, ^token} = Session.auth(config)
    assert {:ok, [%{"status" => "OK", "result" => 1}]} = Surreal.query("RETURN 1;")
  end

  test "a token for different connection settings is never reused" do
    config = RuntimeConfig.surrealdb!()
    assert {:bearer, token} = Session.auth(config)

    # Nothing listens on port 9, so sign-in fails and basic auth is used.
    other = %{config | url: "http://127.0.0.1:9"}
    assert {:basic, _} = Session.auth(other)
    refute Session.auth(other) == {:bearer, token}
  end

  test "a rejected token is renewed and the query still succeeds" do
    config = RuntimeConfig.surrealdb!()
    assert {:bearer, _token} = Session.auth(config)

    fingerprint = :erlang.phash2({config.url, config.username, config.password})
    expires_at = System.system_time(:second) + 3_600
    :persistent_term.put({Session, :token}, {fingerprint, "revoked.token.value", expires_at})

    assert {:ok, [%{"status" => "OK", "result" => 1}]} = Surreal.query("RETURN 1;")
    assert {:bearer, renewed} = Session.auth(config)
    refute renewed == "revoked.token.value"
  end
end
