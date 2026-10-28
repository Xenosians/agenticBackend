defmodule ItsmBackend.Topologies.SurrealStore do
  @moduledoc false

  alias ItsmBackend.Surreal

  @table "topology"

  def create(topology) do
    statement = "CREATE ONLY type::record($table, $id) CONTENT $topology RETURN AFTER;"

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @table,
             "id" => topology["topology_id"],
             "topology" =>
               Surreal.datetime_fields(topology, ~w(created_at updated_at archived_at))
           }),
         {:ok, record} when is_map(record) <- single(results),
         stored = normalize(record),
         true <-
           matches_fields?(
             stored,
             Map.take(topology, ~w(topology_id user_id version name design design_sha256 layout))
           ) do
      {:ok, stored}
    else
      {:ok, nil} -> {:error, :topology_not_created}
      false -> {:error, :topology_write_outcome_unknown}
      error -> error
    end
  end

  def get(topology_id) do
    statement = "SELECT * FROM ONLY type::record($table, $id);"

    with {:ok, results} <- Surreal.query(statement, %{"table" => @table, "id" => topology_id}),
         {:ok, record} <- single(results) do
      {:ok, record && normalize(record)}
    end
  end

  def list_for_user(user_id, limit) do
    statement = """
    SELECT * FROM topology
    WHERE user_id = $user_id AND archived_at = $archived_at
    ORDER BY updated_at DESC
    LIMIT $limit;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "user_id" => user_id,
             "archived_at" => nil,
             "limit" => limit
           }),
         {:ok, rows} <- rows(results) do
      {:ok,
       Enum.map(rows || [], fn row ->
         row
         |> normalize()
         |> Map.take(~w(topology_id name version design_sha256 updated_at))
       end)}
    end
  end

  @doc """
  Writes a new version only while the stored version is still `base`; a
  concurrent save leaves zero rows updated and becomes a version conflict.
  """
  def update_version(user_id, topology_id, base, input, now) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET name = $name, design = $design, design_sha256 = $digest,
        layout = $layout, version = version + 1, updated_at = $now
    WHERE user_id = $owner AND version = $base AND archived_at = $archived_at
    RETURN AFTER;
    """

    params = %{
      "table" => @table,
      "id" => topology_id,
      "owner" => user_id,
      "name" => input["name"],
      "design" => input["design"],
      "digest" => input["design_sha256"],
      "layout" => input["layout"],
      "base" => base,
      "archived_at" => nil,
      "now" => Surreal.datetime(now)
    }

    with {:ok, results} <- Surreal.query(statement, params),
         {:ok, record} <- single(results) do
      cond do
        is_nil(record) ->
          {:error, :version_conflict}

        matches_fields?(
          record,
          Map.merge(input, %{
            "topology_id" => topology_id,
            "user_id" => user_id,
            "version" => base + 1
          })
        ) ->
          {:ok, normalize(record)}

        true ->
          {:error, :topology_write_outcome_unknown}
      end
    end
  end

  def archive(user_id, topology_id, now) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET archived_at = $now, updated_at = $now
    WHERE user_id = $owner AND archived_at = $empty
    RETURN AFTER;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @table,
             "id" => topology_id,
             "owner" => user_id,
             "empty" => nil,
             "now" => Surreal.datetime(now)
           }),
         {:ok, record} <- single(results) do
      cond do
        is_nil(record) ->
          {:error, :not_found}

        record["topology_id"] == topology_id and record["user_id"] == user_id and
            not is_nil(record["archived_at"]) ->
          {:ok, normalize(record)}

        true ->
          {:error, :topology_write_outcome_unknown}
      end
    end
  end

  defp normalize(record) do
    record
    |> Map.delete("id")
    |> Map.update("created_at", nil, &encode_time/1)
    |> Map.update("updated_at", nil, &encode_time/1)
    |> Map.update("archived_at", nil, &encode_time/1)
  end

  defp matches_fields?(record, expected),
    do: is_map(record) and Enum.all?(expected, fn {field, value} -> record[field] === value end)

  defp encode_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_time(value), do: value

  defp single(results) do
    with {:ok, result} <- rows(results) do
      case result do
        nil -> {:ok, nil}
        [] -> {:ok, nil}
        [record] when is_map(record) -> {:ok, record}
        record when is_map(record) -> {:ok, record}
        other -> {:error, {:unexpected_topology_result, other}}
      end
    end
  end

  defp rows([%{"status" => "OK", "result" => result} | _]), do: {:ok, result}
  defp rows(other), do: {:error, {:unexpected_surreal_response, other}}
end
