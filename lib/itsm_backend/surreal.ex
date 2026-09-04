defmodule ItsmBackend.Surreal do
  @moduledoc """
  Minimal SurrealDB HTTP RPC client.

  Uses the RPC query method so SurrealQL variables can
  contain nested JSON values such as maps and lists.
  """

  @spec query(String.t(), map()) ::
          {:ok, list()}
          | {:error, term()}
  def query(statement, params \\ %{})
      when is_binary(statement) and
             is_map(params) do
    config =
      Application.fetch_env!(
        :itsm_backend,
        :surrealdb
      )

    url =
      Keyword.fetch!(
        config,
        :url
      )

    namespace =
      Keyword.fetch!(
        config,
        :namespace
      )

    database =
      Keyword.fetch!(
        config,
        :database
      )

    username =
      Keyword.fetch!(
        config,
        :username
      )

    password =
      Keyword.fetch!(
        config,
        :password
      )

    request_id =
      System.unique_integer([:positive])

    payload = %{
      "id" => request_id,
      "method" => "query",
      "params" => [
        statement,
        params
      ]
    }

    case Req.post(
           "#{url}/rpc",
           headers: [
             {"surreal-ns", namespace},
             {"surreal-db", database},
             {"accept", "application/json"}
           ],
           auth: {
             :basic,
             "#{username}:#{password}"
           },
           json: payload
         ) do
      {:ok, %{status: status, body: body}}
      when status in 200..299 ->
        normalize_response(
          body,
          request_id
        )

      {:ok, %{status: status, body: body}} ->
        {:error,
         {
           :surreal_http_error,
           status,
           body
         }}

      {:error, reason} ->
        {:error,
         {
           :surreal_request_failed,
           reason
         }}
    end
  end

  defp normalize_response(
         %{
           "id" => response_id,
           "result" => result
         },
         request_id
       )
       when response_id == request_id and
              is_list(result) do
    normalize_query_results(result)
  end

  defp normalize_response(
         %{
           "error" => error
         },
         _request_id
       ) do
    {:error,
     {
       :surreal_rpc_error,
       error
     }}
  end

  defp normalize_response(
         body,
         _request_id
       ) do
    {:error,
     {
       :unexpected_surreal_response,
       body
     }}
  end

  defp normalize_query_results(results) do
    case Enum.find(
           results,
           fn item ->
             Map.get(
               item,
               "status"
             ) != "OK"
           end
         ) do
      nil ->
        {:ok, results}

      error ->
        {:error,
         {
           :surreal_query_error,
           error
         }}
    end
  end
end
