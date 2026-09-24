defmodule ItsmBackend.Auth.Password do
  @moduledoc """
  Password hashing and verification using PBKDF2-HMAC-SHA256 from OTP.

  Passwords are never persisted or logged in plaintext.
  """

  @algorithm "pbkdf2-sha256-v1"
  @iterations 210_000
  @salt_bytes 16
  @derived_bytes 32

  @spec hash(String.t()) :: {:ok, String.t()} | {:error, :invalid_password}
  def hash(password) when is_binary(password) do
    with :ok <- validate(password) do
      salt = :crypto.strong_rand_bytes(@salt_bytes)
      derived = derive(password, salt, @iterations)

      {:ok,
       Enum.join(
         [
           @algorithm,
           Integer.to_string(@iterations),
           Base.url_encode64(salt, padding: false),
           Base.url_encode64(derived, padding: false)
         ],
         "$"
       )}
    end
  end

  def hash(_), do: {:error, :invalid_password}

  @spec verify(String.t(), String.t()) :: boolean()
  def verify(password, encoded)
      when is_binary(password) and is_binary(encoded) do
    with [@algorithm, iterations_text, salt_b64, expected_b64] <-
           String.split(encoded, "$"),
         {iterations, ""} when iterations > 0 <- Integer.parse(iterations_text),
         {:ok, salt} <- Base.url_decode64(salt_b64, padding: false),
         {:ok, expected} <- Base.url_decode64(expected_b64, padding: false),
         true <- byte_size(expected) == @derived_bytes do
      actual = derive(password, salt, iterations)
      secure_compare(actual, expected)
    else
      _ -> false
    end
  end

  def verify(_, _), do: false

  @doc "Performs comparable work when an email address is unknown."
  @spec burn(String.t()) :: :ok
  def burn(password) when is_binary(password) do
    _ = derive(password, <<0::128>>, @iterations)
    :ok
  end

  def burn(_), do: :ok

  @spec validate(String.t()) :: :ok | {:error, :invalid_password}
  def validate(password) when is_binary(password) do
    length = String.length(password)

    if length >= 12 and length <= 128 do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  def validate(_), do: {:error, :invalid_password}

  defp derive(password, salt, iterations) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, @derived_bytes)
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_, _), do: false
end
