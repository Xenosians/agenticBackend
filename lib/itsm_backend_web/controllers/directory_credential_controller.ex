defmodule ItsmBackendWeb.DirectoryCredentialController do
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  request_contract(:create,
    required_body: ["directory_user_id", "temporary_password"],
    optional_body: []
  )

  alias ItsmBackend.DirectoryCredentials
  alias ItsmBackend.RuntimeConfig

  def create(conn, _params) do
    if authorized?(conn) do
      persist(conn, conn.body_params)
    else
      conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
    end
  end

  defp persist(conn, payload) do
    case DirectoryCredentials.persist(payload) do
      {:ok, result} ->
        conn |> put_status(:created) |> json(result)

      {:error, {:invalid_field, field}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_request", field: field})

      {:error, :invalid_payload} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_request"})

      {:error, :credential_vault_configuration} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "credential_vault_configuration"})

      {:error, _reason} ->
        # Secrets and raw database/encryption errors never enter the response.
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "credential_persistence_failed"})
    end
  end

  defp authorized?(conn) do
    expected = RuntimeConfig.internal_job_token!()

    case get_req_header(conn, "x-internal-token") do
      [provided] when byte_size(provided) == byte_size(expected) ->
        Plug.Crypto.secure_compare(provided, expected)

      _ ->
        false
    end
  end
end
