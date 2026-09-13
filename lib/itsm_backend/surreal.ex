defmodule ItsmBackend.Surreal do
  @moduledoc """
  Minimal SurrealDB HTTP RPC client.

  Uses the RPC query method so SurrealQL variables can
  contain nested JSON values such as maps and lists.

  Deployment-specific connection settings are resolved through
  RuntimeConfig so the data-access layer does not read raw
  application configuration directly.
  """

  alias ItsmBackend.RuntimeConfig

  @spec query(String.t(), map()) ::
          {:ok, list()}
          | {:error, term()}
  def query(
        statement,
        params \\ %{}
      )
      when is_binary(statement) and
             is_map(params) do
    config =
      RuntimeConfig.surrealdb!()

    request_id =
      System.unique_integer([
        :positive
      ])

    payload = %{
      "id" =>
        request_id,
      "method" =>
        "query",
      "params" => [
        statement,
        params
      ]
    }

    case Req.post(
           "#{config.url}/rpc",
           headers: [
             {
               "surreal-ns",
               config.namespace
             },
             {
               "surreal-db",
               config.database
             },
             {
               "accept",
               "application/json"
             }
           ],
           auth: {
             :basic,
             "#{config.username}:#{config.password}"
           },
           json:
             payload
         ) do
      {:ok,
       %{
         status: status,
         body: body
       }}
      when status in 200..299 ->
        normalize_response(
          body,
          request_id
        )

      {:ok,
       %{
         status: status,
         body: body
       }} ->
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

  # ------------------------------------------------------------
  # RPC response
  # ------------------------------------------------------------

  defp normalize_response(
         %{
           "id" =>
             response_id,
           "result" =>
             result
         },
         request_id
       )
       when response_id ==
              request_id and
              is_list(result) do
    normalize_query_results(
      result
    )
  end

  defp normalize_response(
         %{
           "error" =>
             error
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

  # ------------------------------------------------------------
  # SurrealQL results
  # ------------------------------------------------------------

  defp normalize_query_results(
         results
       ) do
    case Enum.find(
           results,
           fn item ->
             Map.get(
               item,
               "status"
             ) !=
               "OK"
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
