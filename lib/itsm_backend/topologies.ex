defmodule ItsmBackend.Topologies do
  @moduledoc """
  Saved, owner-scoped infrastructure topologies (SRS 1.9 FR-093, V19-09).

  A topology is the owner's desired graph plus the canvas layout it was drawn
  with, saved as versions. It is desired state only: saving or checking a
  topology never changes a device. Drift sends one exact saved version to the
  AI service, which observes through fixed read adapters and compares.
  """

  alias ItsmBackend.Topologies.SurrealStore

  @name_max 120
  @coordinate_limit 100_000
  @list_limit 200
  @identity ~r/\A[0-9a-f]{32}\z/
  @node_id ~r/\A[a-z][a-z0-9_]{0,31}:[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}\z/
  @kind ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @property ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @private_name ~r/pass(word|wd)?|secret|token|credential|api_?key|private_?key|cookie|authorization/
  # Credential and personal-data shapes; ordinary words such as "Basic switch" pass.
  @private_text ~r/\b(?:bearer|basic)\s+[A-Za-z0-9._~+\/=-]{16,}|\b(?:password|passwd|secret|api[_-]?key|token|client[_-]?secret)\s*[:=]\s*[^\s,;]+|https?:\/\/[^\/\s:@]+:[^@\s\/]+@|-----BEGIN [A-Z ]*PRIVATE KEY|\b[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\b/i
  @relations ~w(depends_on hosted_on connected_to associated_with)
  @max_nodes 300
  @max_edges 1200
  @max_properties 40
  @max_label 120
  @max_text 200
  @safe_integer 9_007_199_254_740_992

  @doc "The owner's active topologies, most recently updated first."
  def list(user), do: SurrealStore.list_for_user(user["user_id"], @list_limit)

  @doc "One of the owner's topologies; another owner's is reported as missing."
  def get(user, topology_id) do
    with true <- Regex.match?(@identity, to_string(topology_id)) || {:error, :not_found},
         {:ok, topology} when is_map(topology) <- SurrealStore.get(topology_id),
         true <- topology["user_id"] == user["user_id"] || {:error, :not_found},
         true <- is_nil(topology["archived_at"]) || {:error, :not_found} do
      {:ok, public(topology)}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def create(user, params) do
    with {:ok, input} <- validate(params) do
      now = now()

      topology =
        Map.merge(input, %{
          "topology_id" => random_id(),
          "user_id" => user["user_id"],
          "version" => 1,
          "created_at" => now,
          "updated_at" => now,
          "archived_at" => nil
        })

      with {:ok, stored} <- SurrealStore.create(topology), do: {:ok, public(stored)}
    end
  end

  @doc """
  Saves a new version. `base_version` must be the version the editor loaded;
  a concurrent save makes it stale and is reported as a conflict.
  """
  def update(user, topology_id, params) do
    with {:ok, current} <- get(user, topology_id),
         base when is_integer(base) <- params["base_version"] || {:error, :invalid_topology},
         true <- base == current["version"] || {:error, :version_conflict},
         {:ok, input} <- validate(params),
         {:ok, stored} <-
           SurrealStore.update_version(user["user_id"], topology_id, base, input, now()) do
      {:ok, public(stored)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_topology}
    end
  end

  def archive(user, topology_id) do
    with {:ok, _topology} <- get(user, topology_id),
         {:ok, _} <- SurrealStore.archive(user["user_id"], topology_id, now()) do
      :ok
    end
  end

  @doc """
  The exact saved version to check for drift. A stale version is a conflict,
  so a report always describes the version the owner is looking at.
  """
  def for_drift(user, topology_id, version) do
    with {:ok, topology} <- get(user, topology_id),
         true <- (is_integer(version) and version > 0) || {:error, :invalid_topology},
         true <- version == topology["version"] || {:error, :version_conflict} do
      {:ok, topology}
    end
  end

  defp validate(params) when is_map(params) do
    with {:ok, name} <- name(params["name"]),
         {:ok, design} <- design(params["design"]),
         {:ok, layout} <- layout(params["layout"], design) do
      {:ok,
       %{
         "name" => name,
         "design" => design,
         "design_sha256" => digest(design),
         "layout" => layout
       }}
    end
  end

  defp validate(_), do: {:error, :invalid_topology}

  defp name(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and String.length(value) <= @name_max,
      do: {:ok, value},
      else: {:error, :invalid_topology}
  end

  defp name(_), do: {:error, :invalid_topology}

  defp design(%{"nodes" => nodes, "edges" => edges} = design)
       when map_size(design) == 2 and is_list(nodes) and is_list(edges) and
              length(nodes) <= @max_nodes and length(edges) <= @max_edges do
    with {:ok, ids} <- nodes(nodes),
         :ok <- edges(edges, ids) do
      {:ok, design}
    end
  end

  defp design(_), do: {:error, :invalid_topology}

  defp nodes(nodes) do
    Enum.reduce_while(nodes, {:ok, MapSet.new()}, fn node, {:ok, ids} ->
      case graph_node(node) do
        {:ok, id} ->
          if MapSet.member?(ids, id),
            do: {:halt, {:error, :invalid_topology}},
            else: {:cont, {:ok, MapSet.put(ids, id)}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp graph_node(
         %{"id" => id, "kind" => kind, "label" => label, "properties" => properties} = node
       )
       when map_size(node) == 4 and is_binary(id) and is_binary(kind) and is_map(properties) do
    with true <-
           (Regex.match?(@node_id, id) and Regex.match?(@kind, kind)) ||
             {:error, :invalid_topology},
         :ok <- text(label, @max_label),
         :ok <- properties(properties) do
      {:ok, id}
    end
  end

  defp graph_node(_), do: {:error, :invalid_topology}

  defp properties(properties) when map_size(properties) <= @max_properties do
    Enum.reduce_while(properties, :ok, fn {name, value}, :ok ->
      case property(name, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp properties(_), do: {:error, :invalid_topology}

  defp property(name, value) do
    cond do
      not Regex.match?(@property, name) -> {:error, :invalid_topology}
      Regex.match?(@private_name, name) -> {:error, :private_content}
      true -> value(value)
    end
  end

  defp value(value) when is_nil(value) or is_boolean(value), do: :ok
  defp value(value) when is_integer(value) and abs(value) <= @safe_integer, do: :ok
  defp value(value) when is_float(value), do: :ok
  defp value(value) when is_binary(value), do: text(value, @max_text)
  defp value(_), do: {:error, :invalid_topology}

  defp text(value, limit) when is_binary(value) do
    cond do
      String.length(value) > limit or String.contains?(value, ["\r", "\n", "\t", <<0>>]) ->
        {:error, :invalid_topology}

      Regex.match?(@private_text, value) ->
        {:error, :private_content}

      true ->
        :ok
    end
  end

  defp text(_, _), do: {:error, :invalid_topology}

  defp edges(edges, ids) do
    Enum.reduce_while(edges, {:ok, MapSet.new()}, fn
      %{"from" => from, "to" => to, "relation" => relation} = edge, {:ok, seen}
      when map_size(edge) == 3 ->
        key = {from, to, relation}

        if MapSet.member?(ids, from) and MapSet.member?(ids, to) and from != to and
             relation in @relations and not MapSet.member?(seen, key),
           do: {:cont, {:ok, MapSet.put(seen, key)}},
           else: {:halt, {:error, :invalid_topology}}

      _, _ ->
        {:halt, {:error, :invalid_topology}}
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # Every node has exactly one finite position; geometry is never sent for checks.
  defp layout(value, %{"nodes" => nodes}) when is_map(value) do
    ids = MapSet.new(nodes, & &1["id"])

    valid? =
      MapSet.new(Map.keys(value)) == ids and
        Enum.all?(value, fn
          {_id, %{"x" => x, "y" => y} = position} when map_size(position) == 2 ->
            coordinate?(x) and coordinate?(y)

          _ ->
            false
        end)

    if valid?, do: {:ok, value}, else: {:error, :invalid_topology}
  end

  defp layout(_, _), do: {:error, :invalid_topology}

  defp coordinate?(value) when is_integer(value), do: abs(value) <= @coordinate_limit
  defp coordinate?(_), do: false

  # Canonical JSON (sorted keys) so the digest does not depend on map order.
  defp digest(design) do
    :crypto.hash(:sha256, canonical(design)) |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    body =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, item} -> Jason.encode!(key) <> ":" <> canonical(item) end)

    "{" <> body <> "}"
  end

  defp canonical(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical/1) <> "]"

  defp canonical(value), do: Jason.encode!(value)

  defp public(topology) do
    topology
    |> Map.take(~w(topology_id name version design design_sha256 layout created_at updated_at))
    |> Map.put("state_kind", "desired")
  end

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
end
