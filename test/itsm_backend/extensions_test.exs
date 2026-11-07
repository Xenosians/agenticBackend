defmodule ItsmBackend.ExtensionsTest do
  @moduledoc """
  Owner-scoped lifecycle for user Lua extension records (Stage 4.2).

  Registration pins the validated manifest and its digests, moves
  pending -> reviewed -> active with a durable off switch, and revokes
  without dispatching anything. Another owner sees :not_found for every
  operation; a replayed transition is idempotent, never a second event.
  """
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.Extensions
  alias ItsmBackendWeb.AuthTestSupport

  @manifest %{
    "schema" => "extension-manifest.v1",
    "id" => "lua-row-transform",
    "version" => "1.0.0",
    "contract_version" => 1,
    "input_schema" => "urn:agentic-itsm:contracts:v1:extensions:invocation",
    "output_schema" => "urn:agentic-itsm:contracts:v1:extensions:result",
    "limits" => %{
      "max_source_bytes" => 20000,
      "max_input_bytes" => 2_000_000,
      "max_rows" => 10000,
      "max_output_bytes" => 2_000_000,
      "max_instructions" => 20_000_000,
      "max_memory_bytes" => 67_108_864,
      "max_cpu_seconds" => 10,
      "max_address_space_bytes" => 805_306_368,
      "max_wall_seconds" => 20
    }
  }

  setup do
    %{owner: AuthTestSupport.authenticated_identity!()}
  end

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "lua_plugin",
        "manifest" => @manifest,
        "source_type" => "lua_source",
        "source_sha256" =>
          :crypto.hash(:sha256, "return function(row) return row end")
          |> Base.encode16(case: :lower)
      },
      overrides
    )
  end

  defp register!(user, overrides \\ %{}) do
    {:ok, record} = Extensions.register(user, params(overrides))
    record
  end

  test "register pins the manifest and starts pending", %{owner: owner} do
    record = register!(owner.user)

    assert record["record_id"] =~ ~r/\A[0-9a-f]{32}\z/
    assert record["user_id"] == owner.user["user_id"]
    assert record["kind"] == "lua_plugin"
    assert record["extension_id"] == "lua-row-transform"
    assert record["extension_version"] == "1.0.0"
    assert record["status"] == "pending"
    assert record["source_type"] == "lua_source"
    assert record["source_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert record["manifest_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert record["manifest"] == @manifest
    assert record["record_version"] == 1

    assert {:ok, fetched} = Extensions.get(owner.user, record["record_id"])
    assert fetched["record_id"] == record["record_id"]

    assert {:ok, [listed]} = Extensions.list(owner.user)
    assert listed["record_id"] == record["record_id"]
  end

  test "an explicitly supplied manifest digest must match the canonical manifest", %{owner: owner} do
    {:ok, registered} = Extensions.register(owner.user, params())

    canonical =
      @manifest
      |> Jason.encode!()
      |> then(fn _ -> digest_for(@manifest) end)

    assert {:ok, record} =
             Extensions.register(
               owner.user,
               params(%{"manifest_sha256" => canonical})
             )

    assert record["record_id"] == registered["record_id"]

    assert {:error, :invalid_extension} =
             Extensions.register(
               owner.user,
               params(%{"manifest_sha256" => String.duplicate("f", 64)})
             )
  end

  defp digest_for(manifest) do
    canonical = canonical(manifest)
    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    inner =
      value
      |> Enum.sort_by(fn {key, _} -> to_string(key) end)
      |> Enum.map(fn {key, val} -> "#{Jason.encode!(to_string(key))}:#{canonical(val)}" end)
      |> Enum.join(",")

    "{" <> inner <> "}"
  end

  defp canonical(value) when is_list(value),
    do: "[" <> (value |> Enum.map(&canonical/1) |> Enum.join(",")) <> "]"

  defp canonical(value), do: Jason.encode!(value)

  test "invalid kind, manifest, source type and digest are rejected", %{owner: owner} do
    assert {:error, :invalid_extension} =
             Extensions.register(owner.user, params(%{"kind" => "mcp_tool"}))

    assert {:error, :invalid_extension} =
             Extensions.register(owner.user, params(%{"source_type" => "zip"}))

    assert {:error, :invalid_extension} =
             Extensions.register(owner.user, params(%{"source_sha256" => "not-a-digest"}))

    bad_manifest = Map.put(@manifest, "version", "not-semver")

    assert {:error, :invalid_extension} =
             Extensions.register(owner.user, params(%{"manifest" => bad_manifest}))

    unknown_field = Map.put(@manifest, "extra", true)

    assert {:error, :invalid_extension} =
             Extensions.register(owner.user, params(%{"manifest" => unknown_field}))

    assert {:error, :invalid_extension} =
             Extensions.register(owner.user, params(%{"manifest" => "not-a-map"}))

    assert {:ok, []} = Extensions.list(owner.user)
  end

  test "a duplicate identity is idempotent only for identical digests", %{owner: owner} do
    first = register!(owner.user)
    second = register!(owner.user)
    assert second["record_id"] == first["record_id"]
    assert second["status"] == "pending"

    assert {:ok, events} = Extensions.events(owner.user, first["record_id"])
    assert Enum.count(events, &(&1["action"] == "register")) == 1

    other_source = String.duplicate("a", 64)

    assert {:error, :identity_conflict} =
             Extensions.register(owner.user, params(%{"source_sha256" => other_source}))
  end

  test "another owner cannot list, inspect, move or audit the record", %{owner: owner} do
    other = AuthTestSupport.authenticated_identity!()
    record = register!(owner.user)

    assert {:ok, []} = Extensions.list(other.user)
    assert {:error, :not_found} = Extensions.get(other.user, record["record_id"])
    assert {:error, :not_found} = Extensions.review(other.user, record["record_id"])
    assert {:error, :not_found} = Extensions.activate(other.user, record["record_id"])
    assert {:error, :not_found} = Extensions.revoke(other.user, record["record_id"])
    assert {:error, :not_found} = Extensions.disable(other.user, record["record_id"])
    assert {:error, :not_found} = Extensions.enable(other.user, record["record_id"])
    assert {:error, :not_found} = Extensions.events(other.user, record["record_id"])

    assert {:ok, unchanged} = Extensions.get(owner.user, record["record_id"])
    assert unchanged["status"] == "pending"
  end

  test "only reviewed records can activate and the off switch is durable", %{owner: owner} do
    record = register!(owner.user)

    assert {:error, {:transition_not_allowed, "pending"}} =
             Extensions.activate(owner.user, record["record_id"])

    assert {:error, {:transition_not_allowed, "pending"}} =
             Extensions.disable(owner.user, record["record_id"])

    assert {:ok, reviewed} = Extensions.review(owner.user, record["record_id"])
    assert reviewed["status"] == "reviewed"
    assert is_binary(reviewed["reviewed_at"])

    assert {:ok, active} = Extensions.activate(owner.user, record["record_id"])
    assert active["status"] == "active"
    assert is_binary(active["activated_at"])

    # A replayed transition is idempotent and writes no duplicate event.
    assert {:ok, replayed} = Extensions.activate(owner.user, record["record_id"])
    assert replayed["status"] == "active"

    assert {:ok, disabled} = Extensions.disable(owner.user, record["record_id"])
    assert disabled["status"] == "disabled"

    assert {:ok, enabled} = Extensions.enable(owner.user, record["record_id"])
    assert enabled["status"] == "active"

    assert {:ok, events} = Extensions.events(owner.user, record["record_id"])
    actions = Enum.map(events, & &1["action"])
    assert actions == ["register", "review", "activate", "disable", "enable"]
  end

  test "revoke is terminal for future transitions", %{owner: owner} do
    record = register!(owner.user)
    {:ok, _} = Extensions.review(owner.user, record["record_id"])
    {:ok, _} = Extensions.activate(owner.user, record["record_id"])

    assert {:ok, revoked} = Extensions.revoke(owner.user, record["record_id"])
    assert revoked["status"] == "revoked"
    assert is_binary(revoked["revoked_at"])

    assert {:error, {:transition_not_allowed, "revoked"}} =
             Extensions.enable(owner.user, record["record_id"])

    assert {:error, {:transition_not_allowed, "revoked"}} =
             Extensions.disable(owner.user, record["record_id"])

    assert {:error, {:transition_not_allowed, "revoked"}} =
             Extensions.activate(owner.user, record["record_id"])
  end

  test "a malformed record id is reported as missing", %{owner: owner} do
    assert {:error, :not_found} = Extensions.get(owner.user, "not-a-record")
    assert {:error, :not_found} = Extensions.review(owner.user, "short")
    assert {:error, :not_found} = Extensions.events(owner.user, "")
  end
end
