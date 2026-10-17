defmodule ItsmBackendWeb.DirectoryCredentialControllerTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.Surreal

  @internal_token "directory-credential-internal-token"
  @secret "Reset-Temporary-Secret!42"

  setup do
    originals =
      Map.new([:internal_job_token, :credential_vault], fn key ->
        {key, Application.get_env(:itsm_backend, key)}
      end)

    Application.put_env(:itsm_backend, :internal_job_token, @internal_token)

    Application.put_env(:itsm_backend, :credential_vault,
      key_b64: Base.encode64(:crypto.strong_rand_bytes(32)),
      key_version: "directory-credential-test-v1",
      ttl_seconds: 3_600
    )

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> Application.delete_env(:itsm_backend, key)
        {key, value} -> Application.put_env(:itsm_backend, key, value)
      end)
    end)

    :ok
  end

  test "requires the internal token", %{conn: conn} do
    assert conn |> post_credential(payload(), nil) |> json_response(401) == %{
             "error" => "unauthorized"
           }

    assert build_conn() |> post_credential(payload(), "wrong-token") |> json_response(401) ==
             %{"error" => "unauthorized"}
  end

  test "stores only ciphertext and returns references", %{conn: conn} do
    result = conn |> post_credential(payload()) |> json_response(201)
    assert result["directory_user_id"] == "reset.user"
    assert is_binary(result["credential_id"])
    assert is_binary(result["credential_expires_at"])
    refute Jason.encode!(result) =~ @secret

    {:ok, stored} =
      Surreal.query("SELECT * FROM ONLY type::record('credential_secret', $id);", %{
        "id" => result["credential_id"]
      })

    serialized = inspect(stored)
    refute serialized =~ @secret
    assert serialized =~ "ciphertext_b64"
    assert serialized =~ "password_reset"
  end

  test "rejects unknown fields and invalid values", %{conn: conn} do
    assert conn
           |> post_credential(Map.put(payload(), "email", "x@itsm.test"))
           |> json_response(422) == %{"error" => "invalid_request"}

    assert build_conn()
           |> post_credential(Map.put(payload(), "temporary_password", "short"))
           |> json_response(422) == %{
             "error" => "invalid_request",
             "field" => "temporary_password"
           }

    assert build_conn()
           |> post_credential(Map.put(payload(), "directory_user_id", " padded"))
           |> json_response(422) == %{
             "error" => "invalid_request",
             "field" => "directory_user_id"
           }
  end

  test "configuration errors do not expose secrets", %{conn: conn} do
    Application.delete_env(:itsm_backend, :credential_vault)
    result = conn |> post_credential(payload()) |> json_response(503)
    assert result == %{"error" => "credential_vault_configuration"}
    refute Jason.encode!(result) =~ @secret
  end

  test "has no credential fetch route", %{conn: conn} do
    assert conn |> get("/api/internal/v1/directory-credentials/missing") |> response(404)
  end

  defp payload, do: %{"directory_user_id" => "reset.user", "temporary_password" => @secret}

  defp post_credential(conn, payload, token \\ @internal_token) do
    conn = put_req_header(conn, "content-type", "application/json")
    conn = if token, do: put_req_header(conn, "x-internal-token", token), else: conn
    post(conn, ~p"/api/internal/v1/directory-credentials", Jason.encode!(payload))
  end
end
