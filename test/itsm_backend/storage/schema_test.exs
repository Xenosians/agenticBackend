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
end
