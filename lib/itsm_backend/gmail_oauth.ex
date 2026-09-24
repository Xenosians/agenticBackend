defmodule ItsmBackend.GmailOAuth do
  @moduledoc """
  Exchanges the configured Google OAuth refresh token for a
  short-lived Gmail API access token.

  The refresh token, client ID, and client secret remain entirely
  on the backend. They are never exposed to the browser.
  """

  @token_url "https://oauth2.googleapis.com/token"

  @spec access_token() :: {:ok, String.t()} | {:error, term()}
  def access_token do
    config =
      Application.get_env(
        :itsm_backend,
        :gmail_api,
        []
      )

    with {:ok, client_id} <-
           fetch_non_empty(
             config,
             :client_id
           ),
         {:ok, client_secret} <-
           fetch_non_empty(
             config,
             :client_secret
           ),
         {:ok, refresh_token} <-
           fetch_non_empty(
             config,
             :refresh_token
           ),
         {:ok, response} <-
           request_access_token(
             client_id,
             client_secret,
             refresh_token
           ),
         {:ok, access_token} <-
           parse_access_token(response) do
      {:ok, access_token}
    end
  end

  defp request_access_token(
         client_id,
         client_secret,
         refresh_token
       ) do
    Req.post(
      @token_url,
      form: [
        client_id: client_id,
        client_secret: client_secret,
        refresh_token: refresh_token,
        grant_type: "refresh_token"
      ]
    )
  end

  defp parse_access_token(%Req.Response{
         status: status,
         body: %{
           "access_token" => access_token
         }
       })
       when status >= 200 and
              status <= 299 and
              is_binary(access_token) and
              byte_size(access_token) > 0 do
    {:ok, access_token}
  end

  defp parse_access_token(%Req.Response{
         status: status,
         body: body
       })
       when status >= 200 and
              status <= 299 do
    {:error,
     {
       :invalid_google_token_response,
       summarize_body(body)
     }}
  end

  defp parse_access_token(%Req.Response{
         status: status,
         body: body
       }) do
    {:error,
     {
       :google_token_exchange_failed,
       status,
       summarize_body(body)
     }}
  end

  defp fetch_non_empty(config, key) do
    case Keyword.get(config, key) do
      value when is_binary(value) ->
        value =
          String.trim(value)

        if value == "" do
          {:error, {:missing_gmail_oauth_config, key}}
        else
          {:ok, value}
        end

      _ ->
        {:error, {:missing_gmail_oauth_config, key}}
    end
  end

  defp summarize_body(%{} = body) do
    Map.take(
      body,
      [
        "error",
        "error_description"
      ]
    )
  end

  defp summarize_body(body)
       when is_binary(body) do
    String.slice(
      body,
      0,
      500
    )
  end

  defp summarize_body(body) do
    inspect(
      body,
      limit: 20,
      printable_limit: 500
    )
  end
end
