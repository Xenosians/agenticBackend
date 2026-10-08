test_database = Application.fetch_env!(:itsm_backend, :surrealdb) |> Keyword.fetch!(:database)

if test_database == String.trim(System.fetch_env!("SURREALDB_DATABASE")) do
  raise "Refusing to run tests against the development/production SurrealDB database"
end

unless Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_-]*\z/, test_database) do
  raise "Test database name must be a simple identifier"
end

# Only schema initialization, never production data copying or deletion.
case ItsmBackend.Surreal.query("DEFINE DATABASE IF NOT EXISTS `#{test_database}`;") do
  {:ok, _} -> :ok
  {:error, reason} -> raise "Unable to initialize isolated test database: #{inspect(reason)}"
end

schema = File.read!(Path.expand("../priv/surreal/schema.surql", __DIR__))

case ItsmBackend.Surreal.query(schema) do
  {:ok, _} -> :ok
  {:error, reason} -> raise "Unable to initialize test schema: #{inspect(reason)}"
end

ExUnit.start()
