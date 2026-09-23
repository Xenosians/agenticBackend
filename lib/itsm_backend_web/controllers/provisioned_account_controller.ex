defmodule ItsmBackendWeb.ProvisionedAccountController do
  use ItsmBackendWeb, :controller

  alias ItsmBackend.ProvisionedAccounts
  alias ItsmBackend.RuntimeConfig

  def create(conn, _params) do
    if authorized?(conn) do
      persist(conn, conn.body_params)
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "unauthorized"})
    end
  end

  defp persist(conn, payload) do
    case ProvisionedAccounts.persist(payload) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> json(result)

      {:error, {:invalid_field, field}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_request", field: field})

      {:error, :invalid_payload} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_request"})

      {:error, {:credential_vault_configuration, _reason}} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "credential_vault_unavailable"})

      {:error, _reason} ->
        # Do not expose encryption/database details. In particular, never
        # include conn.body_params or the temporary credential in errors.
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "provisioned_account_persistence_failed"})
    end
  end

  defp authorized?(conn) do
    expected = RuntimeConfig.internal_job_token!()

    provided =
      conn
      |> get_req_header("x-internal-token")
      |> List.first()

    secure_match?(provided, expected)
  end

  defp secure_match?(provided, expected)
       when is_binary(provided) and
              is_binary(expected) and
              byte_size(provided) == byte_size(expected) do
    Plug.Crypto.secure_compare(provided, expected)
  end

  defp secure_match?(_provided, _expected), do: false
end
