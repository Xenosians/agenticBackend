defmodule ItsmBackend.Auth.PasswordTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.Auth.Password

  test "hashes and verifies without retaining plaintext" do
    password = "correct horse battery staple"
    assert {:ok, encoded} = Password.hash(password)
    refute String.contains?(encoded, password)
    assert Password.verify(password, encoded)
    refute Password.verify("wrong password value", encoded)
  end

  test "requires a reasonable minimum length" do
    assert {:error, :invalid_password} = Password.validate("short")
    assert :ok = Password.validate("twelve-chars!")
  end
end
