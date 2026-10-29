defmodule ItsmBackendWeb.SubmissionIntentController do
  @moduledoc """
  Server-held identity of a browser request before it is dispatched.

  The browser keeps nothing between reloads: it reads the pending request of a
  chat, workflow or learning start here, reserves one before sending it and
  acknowledges it only after the server confirms the original operation.
  """
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract

  alias ItsmBackend.SubmissionIntents
  alias ItsmBackendWeb.{AuthRequest, PublicError}

  request_contract(:show, required_query: ["kind", "target_id"])
  request_contract(:reserve, required_body: ["kind", "target_id", "expected_id", "request"])
  request_contract(:acknowledge, required_body: ["kind", "target_id", "intent_id"])

  def show(conn, params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn) do
      if Enum.sort(Map.keys(params)) == ~w(kind target_id),
        do: respond(conn, SubmissionIntents.get(ctx.user, params["kind"], params["target_id"])),
        else: respond(conn, {:error, :invalid_intent})
    else
      {:error, conn} -> conn
    end
  end

  def reserve(conn, params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      if Enum.sort(Map.keys(params)) == ~w(expected_id kind request target_id) and
           map_size(conn.query_params) == 0,
         do:
           respond(
             conn,
             SubmissionIntents.reserve(
               ctx.user,
               params["kind"],
               params["target_id"],
               params["request"],
               params["expected_id"]
             )
           ),
         else: respond(conn, {:error, :invalid_intent})
    else
      {:error, conn} -> conn
    end
  end

  def acknowledge(conn, params) do
    with {:ok, conn, ctx} <- AuthRequest.require_authenticated(conn, csrf: true) do
      if Enum.sort(Map.keys(params)) == ~w(intent_id kind target_id) and
           map_size(conn.query_params) == 0,
         do:
           respond(
             conn,
             SubmissionIntents.acknowledge(
               ctx.user,
               params["kind"],
               params["target_id"],
               params["intent_id"]
             )
           ),
         else: respond(conn, {:error, :invalid_intent})
    else
      {:error, conn} -> conn
    end
  end

  defp respond(conn, {:ok, slot}), do: json(conn, slot)

  defp respond(conn, {:error, :invalid_intent}),
    do:
      PublicError.render(
        conn,
        :unprocessable_entity,
        "invalid_submission_intent",
        "Check the exact request before reserving its identity."
      )

  defp respond(conn, {:error, reason}) when reason in [:pending_intent, :intent_conflict],
    do:
      PublicError.render(
        conn,
        :conflict,
        "submission_intent_conflict",
        "Another request owns this slot. Reload its saved request before starting another."
      )

  defp respond(conn, _),
    do:
      PublicError.render(
        conn,
        :service_unavailable,
        "submission_intent_unavailable",
        "The saved request could not be confirmed. Keep its identity and check again before sending another request.",
        retryable: true
      )
end
