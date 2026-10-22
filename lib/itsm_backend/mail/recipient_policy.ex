defmodule ItsmBackend.Mail.RecipientPolicy do
  @moduledoc """
  Prevents reserved test recipients from reaching public mail transports.

  Local delivery is a separate routing decision: the configured mailbox lab
  route and in-process development transport do not use this public boundary.
  """

  @spec validate_public(String.t() | {String.t(), String.t()}) ::
          :ok | {:error, :invalid_mail_recipient}
  def validate_public({_name, email}), do: validate_public(email)

  def validate_public(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() |> String.split("@") do
      [local, domain] when local != "" and domain != "" ->
        domain = String.trim_trailing(domain, ".")

        if domain in ["test", "invalid"] or String.ends_with?(domain, [".test", ".invalid"]) do
          {:error, :invalid_mail_recipient}
        else
          :ok
        end

      _ ->
        {:error, :invalid_mail_recipient}
    end
  end

  def validate_public(_recipient), do: {:error, :invalid_mail_recipient}
end
