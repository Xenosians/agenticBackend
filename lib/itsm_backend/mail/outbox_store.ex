defmodule ItsmBackend.Mail.OutboxStore do
  @moduledoc """
  Durable SurrealDB mail outbox.

  The outbox is transport-neutral. It persists rendered messages and delivery
  state while `ItsmBackend.Mail` owns provider delivery.
  """

  alias ItsmBackend.Surreal

  @table "mail_outbox"

  @spec enqueue(map()) :: {:ok, map()} | {:error, term()}
  def enqueue(attrs) when is_map(attrs) do
    with {:ok, dedupe_key} <- required_string(attrs, "dedupe_key"),
         {:ok, recipient_email} <- required_string(attrs, "recipient_email"),
         {:ok, subject} <- required_string(attrs, "subject"),
         {:ok, text_body} <- required_string(attrs, "text_body") do
      id =
        :crypto.hash(:sha256, dedupe_key)
        |> Base.encode16(case: :lower)

      now = now_iso()

      data = %{
        "outbox_id" => id,
        "dedupe_key" => dedupe_key,
        "kind" => optional_string(attrs, "kind") || "notification",
        "recipient_name" => optional_string(attrs, "recipient_name"),
        "recipient_email" => recipient_email,
        "subject" => subject,
        "text_body" => text_body,
        "html_body" => optional_string(attrs, "html_body"),
        "status" => "pending",
        "attempts" => 0,
        "created_at" => now,
        "next_attempt_at" => now,
        "claimed_at" => nil,
        "lease_expires_at" => nil,
        "sent_at" => nil,
        "last_error" => nil
      }

      statement = """
      CREATE ONLY type::record($table, $id)
      CONTENT $data
      RETURN AFTER;
      """

      params = %{
        "table" => @table,
        "id" => id,
        "data" => data
      }

      case Surreal.query(statement, params) do
        {:ok, response} ->
          extract_single_result(response)

        {:error, reason} ->
          case get(id) do
            {:ok, existing} -> {:ok, existing}
            _ -> {:error, reason}
          end
      end
    end
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(id) when is_binary(id) do
    statement = """
    SELECT *
    FROM ONLY type::record($table, $id);
    """

    with {:ok, response} <-
           Surreal.query(statement, %{"table" => @table, "id" => id}),
         {:ok, result} <- extract_result(response) do
      case result do
        nil -> {:error, :not_found}
        [] -> {:error, :not_found}
        record when is_map(record) -> {:ok, record}
        [record] when is_map(record) -> {:ok, record}
        other -> {:error, {:unexpected_mail_outbox_result, other}}
      end
    end
  end

  @spec claim_next(pos_integer()) :: {:ok, map() | nil} | {:error, term()}
  def claim_next(lease_seconds)
      when is_integer(lease_seconds) and lease_seconds > 0 do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    lease_expires_at = DateTime.add(now, lease_seconds, :second)

    statement = """
    UPDATE (
      SELECT id, created_at
      FROM mail_outbox
      WHERE
        (
          status = "pending"
          AND next_attempt_at <= $now
        )
        OR
        (
          status = "processing"
          AND lease_expires_at <= $now
        )
      ORDER BY created_at ASC
      LIMIT 1
    )
    SET
      status = "processing",
      attempts = attempts + 1,
      claimed_at = $now,
      lease_expires_at = $lease_expires_at
    RETURN AFTER;
    """

    with {:ok, response} <-
           Surreal.query(
             statement,
             %{
               "now" => DateTime.to_iso8601(now),
               "lease_expires_at" => DateTime.to_iso8601(lease_expires_at)
             }
           ),
         {:ok, result} <- extract_result(response) do
      case result do
        nil -> {:ok, nil}
        [] -> {:ok, nil}
        record when is_map(record) -> {:ok, record}
        [record] when is_map(record) -> {:ok, record}
        other -> {:error, {:unexpected_mail_claim_result, other}}
      end
    end
  end

  @spec mark_sent(String.t()) :: :ok | {:error, term()}
  def mark_sent(id) when is_binary(id) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET
      status = "sent",
      sent_at = $sent_at,
      lease_expires_at = NONE,
      last_error = NONE
    WHERE status = "processing"
    RETURN AFTER;
    """

    mutate_one(
      statement,
      %{
        "table" => @table,
        "id" => id,
        "sent_at" => now_iso()
      }
    )
  end

  @spec reschedule_or_dead(String.t(), non_neg_integer(), pos_integer(), String.t()) ::
          :ok | {:error, term()}
  def reschedule_or_dead(id, attempts, max_attempts, error)
      when is_binary(id) and is_integer(attempts) and attempts >= 0 and
             is_integer(max_attempts) and max_attempts > 0 and is_binary(error) do
    dead? = attempts >= max_attempts
    status = if dead?, do: "dead", else: "pending"

    delay_seconds =
      min(
        3_600,
        trunc(5 * :math.pow(2, max(attempts - 1, 0)))
      )

    next_attempt_at =
      DateTime.utc_now()
      |> DateTime.add(delay_seconds, :second)
      |> DateTime.truncate(:microsecond)
      |> DateTime.to_iso8601()

    statement = """
    UPDATE ONLY type::record($table, $id)
    SET
      status = $status,
      next_attempt_at = $next_attempt_at,
      lease_expires_at = NONE,
      last_error = $last_error
    WHERE status = "processing"
    RETURN AFTER;
    """

    mutate_one(
      statement,
      %{
        "table" => @table,
        "id" => id,
        "status" => status,
        "next_attempt_at" => next_attempt_at,
        "last_error" => String.slice(error, 0, 1_000)
      }
    )
  end

  defp mutate_one(statement, params) do
    with {:ok, response} <- Surreal.query(statement, params),
         {:ok, result} <- extract_result(response) do
      case result do
        nil -> {:error, :not_found}
        [] -> {:error, :not_found}
        record when is_map(record) -> :ok
        [record] when is_map(record) -> :ok
        other -> {:error, {:unexpected_mail_outbox_update, other}}
      end
    end
  end

  defp extract_result([
         %{
           "result" => result,
           "status" => "OK"
         }
         | _
       ]),
       do: {:ok, result}

  defp extract_result(response),
    do: {:error, {:unexpected_surreal_response, response}}

  defp extract_single_result(response) do
    with {:ok, result} <- extract_result(response) do
      case result do
        record when is_map(record) -> {:ok, record}
        [record] when is_map(record) -> {:ok, record}
        nil -> {:error, :not_found}
        [] -> {:error, :not_found}
        other -> {:error, {:unexpected_single_result, other}}
      end
    end
  end

  defp required_string(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, String.to_atom(key))) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_mail_outbox_field, key}}
          normalized -> {:ok, normalized}
        end

      _ ->
        {:error, {:invalid_mail_outbox_field, key}}
    end
  end

  defp optional_string(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, String.to_atom(key))) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          normalized -> normalized
        end

      _ ->
        nil
    end
  end

  defp now_iso do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end
