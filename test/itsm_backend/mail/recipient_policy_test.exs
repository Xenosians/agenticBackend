defmodule ItsmBackend.Mail.RecipientPolicyTest do
  use ExUnit.Case, async: true

  alias ItsmBackend.Mail.RecipientPolicy

  test "reserved domain matching includes case, subdomains and absolute DNS spelling" do
    for recipient <- [
          "person@test",
          "person@invalid",
          "person@example.test",
          "person@nested.example.invalid",
          " person@EXAMPLE.TEST. ",
          {"Person", "person@example.invalid."}
        ] do
      assert {:error, :invalid_mail_recipient} = RecipientPolicy.validate_public(recipient)
    end
  end

  test "unrelated domain names and address local parts are not blocked" do
    for recipient <- [
          "person@example.com",
          "person@test.example.com",
          "person@example.invalid.example.com",
          "test.invalid@example.com",
          {"Person", "person@testable.com"}
        ] do
      assert :ok = RecipientPolicy.validate_public(recipient)
    end
  end

  test "missing and malformed recipient identities fail before dispatch" do
    for recipient <- [nil, %{}, [], "person", "@example.com", "person@", "person@@example.com"] do
      assert {:error, :invalid_mail_recipient} = RecipientPolicy.validate_public(recipient)
    end
  end
end
