defmodule ItsmBackend.Storage.SchemaTest do
  use ExUnit.Case, async: false

  alias ItsmBackend.{Storage.Schema, Surreal}

  test "deployment bootstrap uses the canonical schema including mailbox uniqueness" do
    assert :ok = Schema.ensure()
    assert :ok = Schema.ensure()
    assert {:ok, [%{"result" => info}]} = Surreal.query("INFO FOR TABLE provisioned_mailbox;")
    assert info["indexes"]["provisioned_mailbox_provider_email"] =~ "UNIQUE"

    canonical =
      :itsm_backend |> :code.priv_dir() |> to_string() |> Path.join("surreal/schema.surql")

    assert Schema.statements() == [File.read!(canonical)]
  end

  test "bootstrap creates its configured namespace and database on a fresh server" do
    # SurrealDB 3 does not create a namespace or database on first use, so a new
    # deployment's bootstrap must define them before its tables.
    original = Application.fetch_env!(:itsm_backend, :surrealdb)
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    fresh = Keyword.merge(original, namespace: "bootstrap_ns_#{suffix}", database: "bootstrap_db")

    Application.put_env(:itsm_backend, :surrealdb, fresh)
    ItsmBackend.Surreal.Session.invalidate()

    try do
      assert :ok = Schema.ensure()
      assert :ok = Schema.ensure()
      assert {:ok, [%{"result" => info}]} = Surreal.query("INFO FOR TABLE submission_intent;")
      assert is_map(info)
    after
      Application.put_env(:itsm_backend, :surrealdb, original)
      ItsmBackend.Surreal.Session.invalidate()
      {:ok, _} = Surreal.query("REMOVE NAMESPACE IF EXISTS `#{fresh[:namespace]}`;")
    end
  end
end
