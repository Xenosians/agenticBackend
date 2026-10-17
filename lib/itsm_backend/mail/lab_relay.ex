defmodule ItsmBackend.Mail.LabRelay do
  @moduledoc """
  Delivers mail addressed to the local mailbox lab domain through the lab's
  own SMTP submission service instead of the public mail provider.

  Public providers cannot reach `.test` addresses, so without this boundary a
  lab mailbox would never receive application mail. Only recipients at the
  configured lab domain are routed here; every other recipient keeps the
  configured provider. Delivery authenticates as the configured sender
  account on the lab server, which accepts mail only for its own domain.
  """

  import Swoosh.Email

  alias ItsmBackend.RuntimeConfig

  @doc "True when every recipient address belongs to the configured lab domain."
  @spec handles?(String.t() | {String.t(), String.t()}) :: boolean()
  def handles?(to) do
    case lab_config() do
      {:ok, config} -> lab_address?(address(to), config.domain)
      :disabled -> false
    end
  end

  @spec deliver(
          String.t() | {String.t(), String.t()},
          String.t(),
          String.t(),
          String.t() | nil,
          String.t()
        ) ::
          {:ok, term()} | {:error, term()}
  def deliver(to, subject_value, text_body_value, html_body_value, from_name) do
    with {:ok, config} <- lab_config() do
      email =
        new()
        |> to(to)
        |> from({from_name, config.sender})
        |> subject(subject_value)
        |> text_body(text_body_value)
        |> maybe_html_body(html_body_value)

      Swoosh.Adapters.SMTP.deliver(email,
        relay: config.host,
        port: config.port,
        username: config.sender,
        password: config.password,
        auth: :always,
        tls: :never,
        ssl: false,
        no_mx_lookups: true,
        retries: 0
      )
    else
      :disabled -> {:error, :lab_mail_disabled}
    end
  end

  defp lab_config do
    with config when is_list(config) <- Application.get_env(:itsm_backend, :lab_mail),
         true <- Keyword.get(config, :enabled, false),
         sender when is_binary(sender) and sender != "" <- Keyword.get(config, :sender),
         password when is_binary(password) and password != "" <- Keyword.get(config, :password),
         {:ok, domain} <- lab_domain(),
         true <- lab_address?(sender, domain) do
      {:ok,
       %{
         domain: domain,
         sender: sender,
         password: password,
         host: Keyword.get(config, :host, "127.0.0.1"),
         port: Keyword.get(config, :port, 1587)
       }}
    else
      _ -> :disabled
    end
  end

  defp lab_domain do
    {:ok, RuntimeConfig.mailbox_lab_domain!()}
  rescue
    RuntimeConfig.Error -> :disabled
  end

  defp lab_address?(email, domain) when is_binary(email) do
    case String.split(String.downcase(String.trim(email)), "@") do
      [local, ^domain] when local != "" -> true
      _ -> false
    end
  end

  defp lab_address?(_email, _domain), do: false

  defp address({_name, email}), do: email
  defp address(email), do: email

  defp maybe_html_body(email, value) when is_binary(value) do
    case String.trim(value) do
      "" -> email
      html -> html_body(email, html)
    end
  end

  defp maybe_html_body(email, _value), do: email
end
