defmodule ItsmBackend.Auth.SurrealStore do
  @moduledoc false

  alias ItsmBackend.Surreal

  @user_table "app_user"
  @identity_table "auth_identity"
  @session_table "auth_session"
  @token_table "auth_token"

  def create_registration(user, identity, token) do
    statement = """
    BEGIN TRANSACTION;
    CREATE ONLY type::record($identity_table, $identity_id) CONTENT $identity;
    CREATE ONLY type::record($user_table, $user_id) CONTENT $user;
    CREATE ONLY type::record($token_table, $token_id) CONTENT $token_record;
    COMMIT TRANSACTION;
    """

    params = %{
      "identity_table" => @identity_table,
      "identity_id" => identity["identity_id"],
      "identity" => Surreal.datetime_fields(identity, ~w(created_at)),
      "user_table" => @user_table,
      "user_id" => user["user_id"],
      "user" =>
        Surreal.datetime_fields(
          user,
          ~w(created_at updated_at email_verified_at verification_sent_at)
        ),
      "token_table" => @token_table,
      "token_id" => token["token_id"],
      "token_record" => Surreal.datetime_fields(token, ~w(created_at expires_at consumed_at))
    }

    case Surreal.query(statement, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def find_user_by_email_key(email_key) when is_binary(email_key) do
    statement = """
    SELECT * FROM ONLY type::record($table, $id);
    """

    with {:ok, results} <-
           Surreal.query(statement, %{"table" => @identity_table, "id" => email_key}),
         {:ok, identity} <- single_or_nil(results) do
      case identity do
        nil -> {:ok, nil}
        %{"user_id" => user_id} -> get_user(user_id)
        _ -> {:error, :invalid_identity_record}
      end
    end
  end

  def get_user(user_id) when is_binary(user_id) do
    statement = "SELECT * FROM ONLY type::record($table, $id);"

    with {:ok, results} <-
           Surreal.query(statement, %{"table" => @user_table, "id" => user_id}),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  def create_session(session) when is_map(session) do
    statement = """
    CREATE ONLY type::record($table, $id) CONTENT $session_record RETURN AFTER;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @session_table,
             "id" => session["session_id"],
             "session_record" =>
               Surreal.datetime_fields(session, ~w(created_at last_seen_at expires_at revoked_at))
           }),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  def find_session_by_token_hash(token_hash, now) do
    statement = """
    SELECT * FROM auth_session
    WHERE token_hash = $token_hash
      AND revoked_at = $revoked_at
      AND expires_at > $now
    LIMIT 1;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "token_hash" => token_hash,
             "revoked_at" => nil,
             "now" => Surreal.datetime(now)
           }),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  def find_active_session(session_id, user_id, now) do
    statement = """
    SELECT * FROM auth_session
    WHERE session_id = $session_id AND user_id = $user_id
      AND revoked_at = $revoked_at AND expires_at > $now
    LIMIT 1;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "session_id" => session_id,
             "user_id" => user_id,
             "revoked_at" => nil,
             "now" => Surreal.datetime(now)
           }),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  def touch_session(session_id, now) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET last_seen_at = $now
    RETURN AFTER;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @session_table,
             "id" => session_id,
             "now" => Surreal.datetime(now)
           }),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  def list_sessions(user_id) do
    statement = """
    SELECT * FROM auth_session
    WHERE user_id = $user_id
    ORDER BY created_at DESC;
    """

    with {:ok, results} <- Surreal.query(statement, %{"user_id" => user_id}),
         {:ok, rows} <- result_rows(results) do
      {:ok, rows}
    end
  end

  def revoke_session(session_id, user_id, now) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    SET revoked_at = $now
    WHERE user_id = $user_id AND revoked_at = $not_revoked
    RETURN AFTER;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @session_table,
             "id" => session_id,
             "user_id" => user_id,
             "now" => Surreal.datetime(now),
             "not_revoked" => nil
           }),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  def revoke_all_sessions(user_id, now) do
    statement = """
    UPDATE auth_session
    SET revoked_at = $now
    WHERE user_id = $user_id AND revoked_at = $not_revoked;
    """

    case Surreal.query(statement, %{
           "user_id" => user_id,
           "now" => Surreal.datetime(now),
           "not_revoked" => nil
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def set_task_completed_preference(user_id, enabled) do
    statement = """
    UPDATE ONLY type::record($table, $user_id)
    SET notification_preferences.task_completed = $enabled
    WHERE user_id = $user_id AND status = "active"
    RETURN AFTER;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @user_table,
             "user_id" => user_id,
             "enabled" => enabled
           }),
         {:ok, user} <- single_or_nil(results) do
      {:ok, user}
    end
  end

  def revoke_other_sessions(user_id, current_session_id, now) do
    statement = """
    BEGIN TRANSACTION;
    LET $current = SELECT * FROM ONLY type::record($table, $current_id);
    IF $current = NONE OR $current.user_id != $user_id OR $current.session_id != $current_id
      OR $current.revoked_at != $not_revoked OR $current.expires_at <= $now {
      THROW 'current_session_inactive';
    };
    LET $revoked = UPDATE auth_session SET revoked_at = $now
      WHERE user_id = $user_id AND session_id != $current_id
        AND revoked_at = $not_revoked AND expires_at > $now
      RETURN AFTER;
    RETURN {revoked_sessions: $revoked};
    COMMIT TRANSACTION;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @session_table,
             "current_id" => current_session_id,
             "user_id" => user_id,
             "now" => Surreal.datetime(now),
             "not_revoked" => nil
           }),
         [records] <-
           for(
             %{"status" => "OK", "result" => %{"revoked_sessions" => records}} <- results,
             do: records
           ),
         true <-
           is_list(records) and
             Enum.all?(records, fn record ->
               is_map(record) and record["user_id"] == user_id and
                 is_binary(record["session_id"]) and record["session_id"] != current_session_id and
                 same_time?(record["revoked_at"], now)
             end),
         true <- length(Enum.uniq_by(records, & &1["session_id"])) == length(records) do
      {:ok, length(records)}
    else
      _ -> {:error, :session_revoke_unconfirmed}
    end
  end

  defp same_time?(stored, expected) when is_binary(stored) do
    with {:ok, left, _} <- DateTime.from_iso8601(stored),
         {:ok, right, _} <- DateTime.from_iso8601(expected) do
      DateTime.compare(left, right) == :eq
    else
      _ -> false
    end
  end

  defp same_time?(_, _), do: false

  @doc """
  Records one more verification email for a pending account, only if no other
  send was recorded since `previous_count` was read. `{:ok, nil}` means another
  request claimed it first or the account is no longer pending.
  """
  def claim_verification_send(user_id, previous_count, now)
      when is_binary(user_id) and is_integer(previous_count) do
    statement = """
    UPDATE ONLY type::record($table, $user_id)
    SET verification_sent_at = $now,
        verification_send_count = $next_count,
        updated_at = $now
    WHERE status = "pending_verification"
      AND (verification_send_count ?? 0) = $previous_count
    RETURN AFTER;
    """

    with {:ok, results} <-
           Surreal.query(statement, %{
             "table" => @user_table,
             "user_id" => user_id,
             "now" => Surreal.datetime(now),
             "previous_count" => previous_count,
             "next_count" => previous_count + 1
           }),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  def create_token(token) do
    statement = """
    CREATE ONLY type::record($table, $id) CONTENT $token_record RETURN AFTER;
    """

    case Surreal.query(statement, %{
           "table" => @token_table,
           "id" => token["token_id"],
           "token_record" => Surreal.datetime_fields(token, ~w(created_at expires_at consumed_at))
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def get_token(token_id) when is_binary(token_id) do
    statement = "SELECT * FROM ONLY type::record($table, $id);"

    with {:ok, results} <-
           Surreal.query(statement, %{"table" => @token_table, "id" => token_id}),
         {:ok, record} <- single_or_nil(results) do
      {:ok, record}
    end
  end

  def mark_email_verified(user_id, token_id, now) do
    statement = """
    BEGIN TRANSACTION;
    UPDATE ONLY type::record($token_table, $token_id)
      SET consumed_at = $now
      WHERE consumed_at = $not_consumed;
    UPDATE ONLY type::record($user_table, $user_id)
      SET status = "active", email_verified_at = $now, updated_at = $now;
    COMMIT TRANSACTION;
    """

    case Surreal.query(statement, %{
           "token_table" => @token_table,
           "token_id" => token_id,
           "user_table" => @user_table,
           "user_id" => user_id,
           "now" => Surreal.datetime(now),
           "not_consumed" => nil
         }) do
      {:ok, _} -> get_user(user_id)
      {:error, reason} -> {:error, reason}
    end
  end

  def reset_password(user_id, token_id, password_hash, now) do
    statement = """
    BEGIN TRANSACTION;
    UPDATE ONLY type::record($token_table, $token_id)
      SET consumed_at = $now
      WHERE consumed_at = $not_consumed;
    UPDATE ONLY type::record($user_table, $user_id)
      SET password_hash = $password_hash, updated_at = $now;
    UPDATE auth_session
      SET revoked_at = $now
      WHERE user_id = $user_id AND revoked_at = $not_revoked;
    COMMIT TRANSACTION;
    """

    case Surreal.query(statement, %{
           "token_table" => @token_table,
           "token_id" => token_id,
           "user_table" => @user_table,
           "user_id" => user_id,
           "password_hash" => password_hash,
           "now" => Surreal.datetime(now),
           "not_consumed" => nil,
           "not_revoked" => nil
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp single_or_nil(results) do
    with {:ok, rows} <- result_rows(results) do
      case rows do
        nil -> {:ok, nil}
        [] -> {:ok, nil}
        [row | _] when is_map(row) -> {:ok, row}
        row when is_map(row) -> {:ok, row}
        other -> {:error, {:unexpected_surreal_result, other}}
      end
    end
  end

  defp result_rows([
         %{"status" => "OK", "result" => result} | _
       ]),
       do: {:ok, result}

  defp result_rows(other), do: {:error, {:unexpected_surreal_response, other}}
end
