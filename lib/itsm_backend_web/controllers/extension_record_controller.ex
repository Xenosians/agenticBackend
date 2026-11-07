defmodule ItsmBackendWeb.ExtensionRecordController do
  @moduledoc """
  Owner-scoped lifecycle for user Lua extension records (Stage 4.2).

  Phoenix owns registration, review, activation, revocation and the
  durable on/off switch. A record grants no permission and executes
  nothing; AI dispatch stays authoritative. Another owner's record is
  reported exactly like a missing one.
  """
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  require Logger

  alias ItsmBackend.Extensions
  alias ItsmBackendWeb.{AuthRequest, PublicError}

  request_contract(:index, [])

  request_contract(:create,
    required_body: ["kind", "manifest", "source_type", "source_sha256"],
    optional_body: ["manifest_sha256"]
  )

  request_contract(:show, [])
  request_contract(:review, [])
  request_contract(:activate, [])
  request_contract(:revoke, [])
  request_contract(:disable, [])
  request_contract(:enable, [])
  request_contract(:events, [])

  def index(conn, _params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      case Extensions.list(ctx.user) do
        {:ok, extensions} -> json(conn, %{extensions: extensions})
        error -> respond(conn, error, :extension)
      end
    else
      {:error, conn} -> conn
    end
  end

  def create(conn, params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      input =
        Map.take(params, ~w(kind manifest source_type source_sha256 manifest_sha256))

      case Extensions.register(ctx.user, input) do
        {:ok, extension} -> conn |> put_status(:created) |> json(%{extension: extension})
        error -> respond(conn, error, :extension)
      end
    else
      {:error, conn} -> conn
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      respond(conn, Extensions.get(ctx.user, id), :extension)
    else
      {:error, conn} -> conn
    end
  end

  def review(conn, %{"id" => id}) do
    mutate(conn, fn user -> Extensions.review(user, id) end)
  end

  def activate(conn, %{"id" => id}) do
    mutate(conn, fn user -> Extensions.activate(user, id) end)
  end

  def revoke(conn, %{"id" => id}) do
    mutate(conn, fn user -> Extensions.revoke(user, id) end)
  end

  def disable(conn, %{"id" => id}) do
    mutate(conn, fn user -> Extensions.disable(user, id) end)
  end

  def enable(conn, %{"id" => id}) do
    mutate(conn, fn user -> Extensions.enable(user, id) end)
  end

  def events(conn, %{"id" => id}) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      case Extensions.events(ctx.user, id) do
        {:ok, events} -> json(conn, %{events: events})
        error -> respond(conn, error, :extension)
      end
    else
      {:error, conn} -> conn
    end
  end

  defp mutate(conn, fun) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      respond(conn, fun.(ctx.user), :extension)
    else
      {:error, conn} -> conn
    end
  end

  defp respond(conn, {:ok, extension}, :extension),
    do: json(conn, %{extension: extension})

  defp respond(conn, {:error, :not_found}, _),
    do:
      PublicError.render(
        conn,
        :not_found,
        "extension_not_found",
        "This extension does not exist."
      )

  defp respond(conn, {:error, :invalid_extension}, _),
    do:
      PublicError.render(
        conn,
        :unprocessable_entity,
        "extension_invalid",
        "Check the kind, manifest, source type and source digest."
      )

  defp respond(conn, {:error, {:transition_not_allowed, current_status}}, _),
    do:
      conn
      |> put_status(:conflict)
      |> json(%{
        error: "extension_transition_not_allowed",
        message: "This extension cannot change state from its current status.",
        current_status: current_status
      })

  defp respond(conn, {:error, :identity_conflict}, _),
    do:
      PublicError.render(
        conn,
        :conflict,
        "extension_identity_conflict",
        "This extension identity already belongs to different content."
      )

  defp respond(conn, {:error, reason}, _), do: unavailable(conn, reason)

  defp unavailable(conn, reason) do
    Logger.error("extension record request failed: #{inspect(reason, limit: 5)}")

    PublicError.render(
      conn,
      :service_unavailable,
      "extension_unavailable",
      "The extension record could not be confirmed. Reload before trying again; no duplicate is created.",
      retryable: true
    )
  end
end
