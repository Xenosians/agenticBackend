defmodule ItsmBackend.Surreal.BindingsTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.Surreal
  alias ItsmBackend.Surreal.Bindings

  test "binds opaque text and nested JSON without embedding user values in SQL" do
    value = %{
      "message" => "VPN: users cannot connect",
      "ip" => "fd00:1234::1",
      "date" => "2026-10-22T07:13:11Z",
      "n" => 3,
      "ok" => true,
      "none" => nil
    }

    assert {:ok, statement, params} = Bindings.bind("RETURN $data;", %{"data" => value})
    assert statement == "RETURN (encoding::json::decode($__itsm_bound_0));"
    assert Jason.decode!(params["__itsm_bound_0"]) == value
    refute statement =~ "VPN"
    refute statement =~ "datetime"
  end

  test "leaves all query literals, quoted identifiers and comments unchanged" do
    query = ~S|RETURN [$value, '$value', "$value", `$value`, item:⟨$value⟩]; -- $value
// $value
/* $value /* nested $value */ */
# $value
|
    assert {:ok, rewritten, _} = Bindings.bind(query, %{"value" => "literal"})

    assert String.replace(rewritten, "(encoding::json::decode($__itsm_bound_0))", "$value") ==
             query

    assert length(Regex.scan(~r/encoding::json::decode/, rewritten)) == 1
  end

  test "escaped quotes do not expose literal parameters to rewriting" do
    query = ~S|RETURN ['escaped\' $value', "escaped\" $value", $value];|
    assert {:ok, rewritten, _} = Bindings.bind(query, %{"value" => "text"})
    assert length(Regex.scan(~r/encoding::json::decode/, rewritten)) == 1
    assert rewritten =~ ~S|'escaped\' $value'|
  end

  test "does not rewrite partial identifiers, unbound locals or parameter-like text" do
    query = "LET $local = 7; RETURN [$id, $identifier, $local];"
    assert {:ok, rewritten, _} = Bindings.bind(query, %{"id" => "x"})
    assert rewritten =~ "LET $local = 7;"
    assert rewritten =~ "$identifier, $local"
    assert length(Regex.scan(~r/encoding::json::decode/, rewritten)) == 1
  end

  test "LET shadowing takes effect after its RHS and remains in its block" do
    query = "RETURN { LET $value = $value; RETURN $value; }; RETURN $value;"
    assert {:ok, rewritten, _} = Bindings.bind(query, %{"value" => 4})
    assert rewritten =~ "LET $value = (encoding::json::decode($__itsm_bound_0)); RETURN $value;"
    assert String.ends_with?(rewritten, "RETURN (encoding::json::decode($__itsm_bound_0));")
  end

  test "generated wire names cannot collide with caller variables" do
    assert {:ok, rewritten, params} =
             Bindings.bind("LET $__itsm_bound_0 = 9; RETURN [$value, $__itsm_bound_0];", %{
               "value" => 3
             })

    assert Map.has_key?(params, "__itsm_bound__0")
    assert rewritten =~ "LET $__itsm_bound_0 = 9;"
    assert rewritten =~ "decode($__itsm_bound__0)"
  end

  test "explicit trusted timestamps become casts while adjacent user dates stay strings" do
    at = "2026-10-22T07:13:11.123456Z"

    value = %{
      "created_at" => Surreal.datetime(at),
      "due_text" => at,
      "nested" => [Surreal.datetime(at), "a:b", %{"at" => Surreal.datetime(at)}]
    }

    assert {:ok, rewritten, params} = Bindings.bind("RETURN $data;", %{"data" => value})
    assert rewritten =~ "<datetime>"
    assert rewritten =~ "object::extend"
    assert Jason.decode!(params["__itsm_bound_0"])["due_text"] == at
    refute rewritten =~ "due_text"
  end

  test "rejects invalid parameter names and non-string map keys" do
    for params <- [
          %{"bad-name" => 1},
          %{:atom_name => 1},
          %{"x; DELETE job" => 1},
          %{"value" => %{atom_key: 1}}
        ] do
      assert {:error, {:invalid_surreal_parameters, _}} = Bindings.bind("RETURN 1;", params)
    end
  end

  test "rejects unsupported values, out-of-range integers and excessive nesting" do
    nested = Enum.reduce(1..66, "leaf", fn _, item -> %{"value" => item} end)

    for value <- [
          {:tuple, 1},
          self(),
          MapSet.new([1]),
          [1 | 2],
          ~N[2026-10-22 07:13:11],
          9_223_372_036_854_775_808,
          -9_223_372_036_854_775_809,
          nested
        ] do
      assert {:error, {:invalid_surreal_parameters, _}} =
               Bindings.bind("RETURN $value;", %{"value" => value})
    end
  end

  test "invalid datetimes and malformed UTF8 fail before transport" do
    for value <- [Surreal.datetime("not-a-date"), Surreal.datetime(12), <<255>>] do
      assert {:error, {:invalid_surreal_parameters, _}} =
               Bindings.bind("RETURN $value;", %{"value" => value})
    end
  end

  test "unterminated literals or comments fail rather than guessing token boundaries" do
    for statement <- ["RETURN '$value", "RETURN `$value", "/* $value", "RETURN item:⟨$value"] do
      assert {:error, {:invalid_surreal_parameters, _}} =
               Bindings.bind(statement, %{"value" => 1})
    end
  end
end
