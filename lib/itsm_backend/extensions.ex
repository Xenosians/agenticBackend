defmodule ItsmBackend.Extensions do
  @moduledoc """
  Owner-scoped lifecycle for user extensions (Stage 4.2).

  Phoenix owns registration, review, activation, revocation and the
  durable on/off switch. Lua/AI dispatch stays authoritative: a record
  here grants no permission and does not execute anything. Source bytes
  are not stored in this slice; only the validated manifest and its
  digests are pinned so a later bytes store can join on the same
  identity.
  """

  alias ItsmBackend.Contracts
  alias ItsmBackend.Extensions.SurrealStore

  @list_limit 200
  @identity ~r/\A[0-9a-f]{32}\z/
  @digest ~r/\A[0-9a-f]{64}\z/
  @allowed_kinds ["lua_plugin"]
  @allowed_source_types ["lua_source"]

  @doc "The owner's extension records, most recently updated first."
  def list(user) do
    case SurrealStore.list_for_user(user["user_id"], @list_limit) do
      {:ok, rows} -> {:ok, Enum.map(rows || [], &public/1)}
      error -> error
    end
  end

  @doc "One of the owner's records; another owner's is reported as missing."
  def get(user, record_id) do
    with true <- valid_record_id?(record_id) || {:error, :not_found},
         {:ok, record} when is_map(record) <- SurrealStore.get(to_string(record_id)),
         true <- record["user_id"] == user["user_id"] || {:error, :not_found} do
      {:ok, public(record)}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Registers one manifest-validated extension for the owner.

  The manifest must validate against the canonical
  `extension-manifest.v1` contract. `manifest_sha256` is computed
  from the canonical JSON of the manifest; an explicitly supplied
  digest must match. The record starts as `pending` and can only
  move through review/activation transitions.
  """
  def register(user, params) when is_map(params) do
    with {:ok, input} <- validate_register(params),
         {:ok, manifest_sha256} <- manifest_digest(input["manifest"]),
         :ok <- verify_supplied_digest(params["manifest_sha256"], manifest_sha256) do
      now = now()
      extension_id = input["manifest"]["id"]
      extension_version = input["manifest"]["version"]

      record_id =
        deterministic_record_id(user["user_id"], input["kind"], extension_id, extension_version)

      record = %{
        "record_id" => record_id,
        "user_id" => user["user_id"],
        "kind" => input["kind"],
        "extension_id" => extension_id,
        "record_version" => 1,
        "extension_version" => extension_version,
        "status" => "pending",
        "source_type" => input["source_type"],
        "source_sha256" => input["source_sha256"],
        "manifest_sha256" => manifest_sha256,
        "manifest" => input["manifest"],
        "created_at" => now,
        "updated_at" => now
      }

      event = register_event(user["user_id"], record_id, now)

      with {:ok, stored} <- SurrealStore.create(record, event), do: {:ok, public(stored)}
    end
  end

  def register(_user, _params), do: {:error, :invalid_extension}

  def review(user, record_id), do: transition(user, record_id, ["pending"], "review", "reviewed")

  def activate(user, record_id),
    do: transition(user, record_id, ["reviewed"], "activate", "active")

  def revoke(user, record_id),
    do: transition(user, record_id, ["reviewed", "active", "disabled"], "revoke", "revoked")

  def disable(user, record_id), do: transition(user, record_id, ["active"], "disable", "disabled")
  def enable(user, record_id), do: transition(user, record_id, ["disabled"], "enable", "active")

  @doc "Audit events for one of the owner's records."
  def events(user, record_id) do
    with {:ok, _record} <- get(user, record_id),
         {:ok, events} <- SurrealStore.list_events(user["user_id"], to_string(record_id), 500) do
      {:ok, Enum.map(events, &public_event/1)}
    end
  end

  # -- internals ---------------------------------------------------------

  defp transition(user, record_id, sources, action, target) do
    with true <- valid_record_id?(record_id) || {:error, :not_found},
         {:ok, current} when is_map(current) <- SurrealStore.get(to_string(record_id)),
         true <- current["user_id"] == user["user_id"] || {:error, :not_found} do
      now = now()

      event = %{
        "event_id" => random_id(),
        "user_id" => user["user_id"],
        "record_id" => to_string(record_id),
        "action" => action,
        "from_status" => current["status"],
        "to_status" => target,
        "created_at" => now
      }

      case SurrealStore.transition(
             user["user_id"],
             to_string(record_id),
             sources,
             action,
             target,
             event
           ) do
        {:ok, stored} ->
          {:ok, public(stored)}

        {:error, {:transition_not_allowed, current_status}} ->
          {:error, {:transition_not_allowed, current_status}}

        {:error, _} = error ->
          error
      end
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp validate_register(params) do
    with {:ok, kind} <- validate_kind(params["kind"]),
         {:ok, manifest} <- validate_manifest(params["manifest"]),
         {:ok, source_type} <- validate_source_type(params["source_type"]),
         {:ok, source_sha256} <- validate_digest(params["source_sha256"]) do
      {:ok,
       %{
         "kind" => kind,
         "manifest" => manifest,
         "source_type" => source_type,
         "source_sha256" => source_sha256
       }}
    end
  end

  defp validate_kind(kind) when kind in @allowed_kinds, do: {:ok, kind}
  defp validate_kind(_), do: {:error, :invalid_extension}

  defp validate_source_type(value) when value in @allowed_source_types, do: {:ok, value}
  defp validate_source_type(_), do: {:error, :invalid_extension}

  defp validate_digest(value) when is_binary(value) do
    if Regex.match?(@digest, value), do: {:ok, value}, else: {:error, :invalid_extension}
  end

  defp validate_digest(_), do: {:error, :invalid_extension}

  defp validate_manifest(value) when is_map(value) do
    case Contracts.validate(:extension_manifest, value) do
      :ok -> {:ok, value}
      _ -> {:error, :invalid_extension}
    end
  end

  defp validate_manifest(_), do: {:error, :invalid_extension}

  defp verify_supplied_digest(nil, _computed), do: :ok

  defp verify_supplied_digest(supplied, computed) when supplied == computed, do: :ok
  defp verify_supplied_digest(_supplied, _computed), do: {:error, :invalid_extension}

  defp manifest_digest(manifest) do
    canonical = canonical_json(manifest)
    {:ok, :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)}
  end

  defp canonical_json(value) when is_map(value) do
    inner =
      value
      |> Enum.sort_by(fn {key, _} -> to_string(key) end)
      |> Enum.map(fn {key, val} -> "#{Jason.encode!(to_string(key))}:#{canonical_json(val)}" end)
      |> Enum.join(",")

    "{" <> inner <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> (value |> Enum.map(&canonical_json/1) |> Enum.join(",")) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp deterministic_record_id(user_id, kind, extension_id, extension_version) do
    material = "#{user_id}|#{kind}|#{extension_id}|#{extension_version}"
    :crypto.hash(:sha256, material) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end

  defp register_event(user_id, record_id, now) do
    %{
      "event_id" => random_id(),
      "user_id" => user_id,
      "record_id" => record_id,
      "action" => "register",
      "from_status" => nil,
      "to_status" => "pending",
      "created_at" => now
    }
  end

  defp public(record) do
    record
    |> Map.take(
      ~w(record_id user_id kind extension_id record_version extension_version status source_type source_sha256 manifest_sha256 manifest created_at updated_at reviewed_at activated_at revoked_at)
    )
  end

  defp public_event(event) do
    Map.take(event, ~w(event_id user_id record_id action from_status to_status created_at))
  end

  defp valid_record_id?(record_id) when is_binary(record_id), do: record_id =~ @identity
  defp valid_record_id?(_), do: false

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
end
