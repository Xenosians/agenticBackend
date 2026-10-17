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
  alias ItsmBackend.Surreal.Session

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
      "id" => request_id,
      "method" => "query",
      "params" => [
        statement,
        params
      ]
    }

    case rpc(config, payload) do
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

  # Bearer token first; a rejected token is renewed once, then the request
  # falls back to basic auth so availability never depends on the token.
  defp rpc(config, payload) do
    auth = Session.auth(config)

    case post_rpc(config, payload, auth) do
      {:ok, %{status: 401}} when elem(auth, 0) == :bearer ->
        Session.invalidate()
        post_rpc(config, payload, Session.auth(config))

      response ->
        response
    end
  end

  defp post_rpc(config, payload, auth) do
    post_rpc(
      "#{config.url}/rpc",
      headers: [
        {"surreal-ns", config.namespace},
        {"surreal-db", config.database},
        {"accept", "application/json"}
      ],
      auth: auth,
      json: payload
    )
  end

  # Finch raises instead of returning when every pooled connection is busy
  # (for example while the database is stalled). Report that as a request
  # failure so callers degrade the same way as for a timeout, instead of
  # crashing the calling process.
  defp post_rpc(url, options) do
    Req.post(url, options)
  rescue
    error in RuntimeError ->
      if String.contains?(Exception.message(error), "unable to provide a connection") do
        {:error, :connection_pool_exhausted}
      else
        reraise error, __STACKTRACE__
      end
  end

  # ------------------------------------------------------------
  # RPC response
  # ------------------------------------------------------------

  defp normalize_response(
         %{
           "id" => response_id,
           "result" => result
         },
         request_id
       )
       when response_id ==
              request_id and
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

  # ------------------------------------------------------------
  # SurrealQL results
  # ------------------------------------------------------------

  defp normalize_query_results(results) do
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
