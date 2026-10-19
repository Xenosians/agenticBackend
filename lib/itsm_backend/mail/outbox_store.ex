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
      CONTENT object::extend(encoding::json::decode($data_json), {
        created_at: <datetime>$now,
        next_attempt_at: <datetime>$now
      })
      RETURN AFTER;
      """

      params = %{
        "table" => @table,
        "id" => id,
        "now" => now,
        # JSON RPC coerces record-shaped string parameters (including nested
        # ones), so a key like job:<id>:1:completed can lose its final segments.
        # Decode one JSON envelope inside SurrealDB to preserve text exactly.
        "data_json" => Jason.encode!(data)
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

    # A crashed sender may have reached the provider. Lease expiry is evidence
    # of uncertainty, never permission to send the message again.
    with :ok <- reconcile_expired_processing(now) do
      claim_pending(now, lease_expires_at)
    end
  end

  defp claim_pending(now, lease_expires_at) do
    statement = """
    UPDATE (
      SELECT id, created_at
      FROM mail_outbox
      WHERE
        status = "pending"
        AND next_attempt_at <= <datetime>$now
      ORDER BY created_at ASC
      LIMIT 1
    )
    SET
      status = "processing",
      attempts = attempts + 1,
      claimed_at = <datetime>$now,
      lease_expires_at = <datetime>$lease_expires_at
    WHERE status = "pending" AND next_attempt_at <= <datetime>$now
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

  @doc "Quarantines interrupted sends. No provider call or resend is performed."
  def reconcile_expired_processing(now \\ DateTime.utc_now()) do
    statement = """
    UPDATE mail_outbox
    SET status = "outcome_unknown",
        lease_expires_at = NONE,
        last_error = "Mail delivery was interrupted. Reconcile provider receipt before another send."
    WHERE status = "processing" AND lease_expires_at <= <datetime>$now
    RETURN AFTER;
    """

    with {:ok, response} <- Surreal.query(statement, %{"now" => DateTime.to_iso8601(now)}),
         {:ok, _records} <- extract_result(response) do
      :ok
    end
  end

  @spec mark_sent(String.t(), pos_integer()) :: :ok | {:error, term()}
  def mark_sent(id, attempt) when is_binary(id) and is_integer(attempt) and attempt > 0 do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET
      status = "sent",
      sent_at = <datetime>$sent_at,
      lease_expires_at = NONE,
      last_error = NONE
    WHERE status = "processing" AND attempts = $attempt
    RETURN AFTER;
    """

    mutate_one(
      statement,
      %{
        "table" => @table,
        "id" => id,
        "attempt" => attempt,
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
      next_attempt_at = <datetime>$next_attempt_at,
      lease_expires_at = NONE,
      last_error = $last_error
    WHERE status = "processing" AND attempts = $attempt
    RETURN AFTER;
    """

    mutate_one(
      statement,
      %{
        "table" => @table,
        "id" => id,
        "attempt" => attempts,
        "status" => status,
        "next_attempt_at" => next_attempt_at,
        "last_error" => String.slice(error, 0, 1_000)
      }
    )
  end

  @doc "Records a non-retryable rejection or an ambiguous delivery for this exact claim."
  def stop_delivery(id, attempt, status, error)
      when is_binary(id) and is_integer(attempt) and attempt > 0 and
             status in ["dead", "outcome_unknown"] and is_binary(error) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET status = $status, lease_expires_at = NONE, last_error = $last_error
    WHERE status = "processing" AND attempts = $attempt
    RETURN AFTER;
    """

    mutate_one(statement, %{
      "table" => @table,
      "id" => id,
      "attempt" => attempt,
      "status" => status,
      "last_error" => String.slice(error, 0, 1_000)
    })
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
