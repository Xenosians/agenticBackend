defmodule ItsmBackend.Mail.Brevo do
  @moduledoc """
  Transactional HTTPS email transport backed by Brevo.

  Authentication uses one server-side static API key. No SMTP session,
  Gmail OAuth access token, or refresh-token exchange is involved.
  """

  @endpoint "https://api.brevo.com/v3/smtp/email"
  @max_attempts 3

  @spec deliver(
          String.t() | {String.t(), String.t()},
          String.t(),
          String.t(),
          String.t() | nil,
          {String.t(), String.t()}
        ) :: {:ok, map()} | {:error, term()}
  def deliver(to, subject, text_body, html_body, {from_name, from_email})
      when is_binary(subject) and is_binary(text_body) and
             is_binary(from_name) and is_binary(from_email) do
    with {:ok, api_key} <- api_key(),
         {:ok, recipient} <- normalize_recipient(to),
         {:ok, sender} <- normalize_sender(from_name, from_email) do
      payload =
        %{
          "sender" => sender,
          "to" => [recipient],
          "subject" => subject,
          "textContent" => text_body
        }
        |> maybe_put_html(html_body)

      request(api_key, payload, 1)
    end
  end

  defp request(api_key, payload, attempt) do
    case Req.post(
           @endpoint,
           headers: [
             {"accept", "application/json"},
             {"api-key", api_key}
           ],
           json: payload,
           receive_timeout: 20_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, %{provider: "brevo", status: status, message_id: message_id(body)}}

      {:ok, %Req.Response{status: status, body: body}}
      when status == 429 or status >= 500 ->
        retry_or_error(
          api_key,
          payload,
          attempt,
          {:brevo_transient_error, status, summarize_body(body)}
        )

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:brevo_delivery_rejected, status, summarize_body(body)}}

      {:error, reason} ->
        retry_or_error(api_key, payload, attempt, {:brevo_request_failed, reason})
    end
  end

  defp retry_or_error(api_key, payload, attempt, _reason) when attempt < @max_attempts do
    Process.sleep(retry_delay_ms(attempt))
    request(api_key, payload, attempt + 1)
  end

  defp retry_or_error(_api_key, _payload, _attempt, reason), do: {:error, reason}

  defp retry_delay_ms(1), do: 500
  defp retry_delay_ms(2), do: 1_500
  defp retry_delay_ms(_attempt), do: 3_000

  defp normalize_recipient({name, email}) when is_binary(name) and is_binary(email) do
    with {:ok, email} <- normalize_email(email) do
      name = String.trim(name)
      value = %{"email" => email} |> maybe_put_name(name)
      {:ok, value}
    end
  end

  defp normalize_recipient(email) when is_binary(email) do
    with {:ok, email} <- normalize_email(email), do: {:ok, %{"email" => email}}
  end

  defp normalize_recipient(_value), do: {:error, :invalid_mail_recipient}

  defp normalize_sender(name, email) do
    with {:ok, email} <- normalize_email(email) do
      name =
        case String.trim(name) do
          "" -> "Agentic ITSM"
          value -> value
        end

      {:ok, %{"name" => name, "email" => email}}
    end
  end

  defp normalize_email(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_mail_address}
    end
  end

  defp maybe_put_name(value, ""), do: value
  defp maybe_put_name(value, name), do: Map.put(value, "name", name)

  defp maybe_put_html(payload, value) when is_binary(value) do
    case String.trim(value) do
      "" -> payload
      html -> Map.put(payload, "htmlContent", html)
    end
  end

  defp maybe_put_html(payload, _value), do: payload

  defp api_key do
    config = Application.get_env(:itsm_backend, :brevo_api, [])

    case Keyword.get(config, :api_key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_brevo_api_key}
          normalized -> {:ok, normalized}
        end

      _ ->
        {:error, :missing_brevo_api_key}
    end
  end

  defp message_id(%{"messageId" => value}) when is_binary(value), do: value
  defp message_id(_body), do: nil

  defp summarize_body(body) when is_map(body), do: Map.take(body, ["code", "message"])
  defp summarize_body(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp summarize_body(body), do: inspect(body, limit: 20, printable_limit: 500)
end
