defmodule ItsmBackend.Auth do
  @moduledoc """
  Application identity, authentication sessions, authorization identity,
  email verification and password-reset token lifecycle.
  """

  alias ItsmBackend.Auth.Password
  alias ItsmBackend.Auth.SurrealStore
  alias ItsmBackend.RuntimeConfig

  @spec register(map()) :: {:ok, map(), String.t(), map()} | {:error, term()}
  def register(attrs) when is_map(attrs) do
    config = RuntimeConfig.auth!()

    with true <- config.registration_enabled || {:error, :registration_disabled},
         {:ok, email} <- normalize_email(value(attrs, "email")),
         {:ok, display_name} <- required_text(value(attrs, "display_name"), 160),
         password when is_binary(password) <- value(attrs, "password"),
         :ok <- Password.validate(password),
         {:ok, existing} <- SurrealStore.find_user_by_email_key(email_key(email)),
         true <- is_nil(existing) || {:error, :email_taken},
         {:ok, password_hash} <- Password.hash(password) do
      now = now()
      user_id = random_id()
      raw_token = random_token()
      token_id = token_hash(raw_token)
      role = if email in config.admin_emails, do: "admin", else: "user"

      user = %{
        "user_id" => user_id,
        "email" => email,
        "display_name" => display_name,
        "password_hash" => password_hash,
        "role" => role,
        "status" => "pending_verification",
        "email_verified_at" => nil,
        # The registration email is the first verification email.
        "verification_sent_at" => now,
        "verification_send_count" => 1,
        "created_at" => now,
        "updated_at" => now
      }

      identity = %{
        "identity_id" => email_key(email),
        "email" => email,
        "user_id" => user_id,
        "created_at" => now
      }

      token = token_record(token_id, user_id, "verify_email", config.verification_ttl_seconds)

      case SurrealStore.create_registration(user, identity, token) do
        :ok ->
          {:ok, verification} = verification_of(user)
          {:ok, public_user(user), raw_token, verification}

        {:error, reason} ->
          case SurrealStore.find_user_by_email_key(email_key(email)) do
            {:ok, %{}} -> {:error, :email_taken}
            _ -> {:error, reason}
          end
      end
    else
      false -> {:error, :registration_disabled}
      nil -> {:error, :invalid_request}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def register(_), do: {:error, :invalid_request}

  @spec login(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()}
          | {:error,
             :invalid_credentials
             | {:email_not_verified, map()}
             | :account_disabled
             | term()}
  def login(email_input, password, user_agent)
      when is_binary(password) do
    with {:ok, email} <- normalize_email(email_input),
         {:ok, user} <- SurrealStore.find_user_by_email_key(email_key(email)) do
      authenticate_user(user, password, user_agent)
    else
      _ ->
        Password.burn(password)
        {:error, :invalid_credentials}
    end
  end

  def login(_, _, _), do: {:error, :invalid_credentials}

  def authenticate_session(raw_token) when is_binary(raw_token) do
    now = now()

    with {:ok, session} <-
           SurrealStore.find_session_by_token_hash(token_hash(raw_token), now),
         true <- is_map(session) || {:error, :invalid_session},
         {:ok, user} <- SurrealStore.get_user(session["user_id"]),
         true <- is_map(user) || {:error, :invalid_session},
         true <- user["status"] == "active" || {:error, :account_inactive} do
      _ = SurrealStore.touch_session(session["session_id"], now)
      {:ok, public_user(user), session}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_session}
    end
  end

  def authenticate_session(_), do: {:error, :invalid_session}

  @doc "Revalidates the persisted identity bound to a signed socket ticket."
  def authenticate_session_id(user_id, session_id)
      when is_binary(user_id) and is_binary(session_id) do
    with {:ok, session} <- SurrealStore.find_active_session(session_id, user_id, now()),
         true <- is_map(session),
         {:ok, user} <- SurrealStore.get_user(user_id),
         true <- is_map(user) and user["status"] == "active" do
      {:ok, public_user(user), session}
    else
      _ -> {:error, :invalid_session}
    end
  end

  def authenticate_session_id(_, _), do: {:error, :invalid_session}

  def list_sessions(user_id, current_session_id) do
    with {:ok, sessions} <- SurrealStore.list_sessions(user_id) do
      {:ok,
       Enum.map(sessions, fn session ->
         %{
           "session_id" => session["session_id"],
           "created_at" => session["created_at"],
           "last_seen_at" => session["last_seen_at"],
           "expires_at" => session["expires_at"],
           "revoked_at" => session["revoked_at"],
           "user_agent" => session["user_agent"],
           "current" => session["session_id"] == current_session_id
         }
       end)}
    end
  end

  def revoke_session(user_id, session_id) do
    SurrealStore.revoke_session(session_id, user_id, now())
  end

  def revoke_other_sessions(user_id, current_session_id) do
    SurrealStore.revoke_other_sessions(user_id, current_session_id, now())
  end

  @doc """
  Ends a session and confirms it can no longer authenticate.

  `:ok` means the session is revoked, now or earlier. Any other result means
  the session may still be valid and must not be reported as ended.
  """
  @spec end_session(String.t(), String.t()) :: :ok | {:error, term()}
  def end_session(user_id, session_id) do
    case SurrealStore.revoke_session(session_id, user_id, now()) do
      {:ok, revoked} when is_map(revoked) -> :ok
      {:ok, nil} -> confirm_session_ended(user_id, session_id)
      {:error, reason} -> {:error, reason}
    end
  end

  # The conditional revoke matched nothing. Confirm that is because the session
  # is no longer active, not because the write was lost.
  defp confirm_session_ended(user_id, session_id) do
    case SurrealStore.find_active_session(session_id, user_id, now()) do
      {:ok, nil} -> :ok
      {:ok, _still_active} -> {:error, :session_still_active}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_email(raw_token) when is_binary(raw_token) do
    with {:ok, token} <- valid_token(raw_token, "verify_email"),
         {:ok, user} <-
           SurrealStore.mark_email_verified(token["user_id"], token["token_id"], now()),
         true <- is_map(user) || {:error, :invalid_token} do
      {:ok, public_user(user)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_token}
    end
  end

  def verify_email(_), do: {:error, :invalid_token}

  @doc """
  The pending verification of `user_id`: when the next email may be sent.

  `{:ok, %{status: "pending", resend_after_seconds: n, email_hint: hint}}` while
  the account waits for verification, `{:ok, %{status: "verified"}}` once it is
  active, and `{:error, :not_pending}` when no account is waiting.
  """
  @spec verification_status(term()) :: {:ok, map()} | {:error, term()}
  def verification_status(user_id) when is_binary(user_id) do
    case SurrealStore.get_user(user_id) do
      {:ok, %{"status" => "pending_verification"} = user} -> verification_of(user)
      {:ok, %{"status" => "active"}} -> {:ok, %{status: "verified"}}
      {:ok, _other} -> {:error, :not_pending}
      {:error, reason} -> {:error, reason}
    end
  end

  def verification_status(_), do: {:error, :not_pending}

  @doc """
  Sends another verification email to the pending account `user_id` once the
  wait since the previous email has passed. The wait doubles after each email,
  up to the configured maximum.

  The send is claimed in storage before a token is created, so two concurrent
  requests cannot both send. `{:error, {:too_soon, seconds}}` reports the time
  left; nothing is sent.
  """
  @spec resend_verification(term()) ::
          {:ok, map(), String.t(), map()} | {:error, term()}
  def resend_verification(user_id) when is_binary(user_id) do
    config = RuntimeConfig.auth!()

    with {:ok, user} <- pending_user(user_id),
         :ok <- resend_allowed(user),
         {:ok, claimed} <- claim_send(user) do
      raw = random_token()

      token =
        token_record(token_hash(raw), user_id, "verify_email", config.verification_ttl_seconds)

      with :ok <- SurrealStore.create_token(token) do
        {:ok, verification} = verification_of(claimed)
        {:ok, public_user(claimed), raw, verification}
      end
    end
  end

  def resend_verification(_), do: {:error, :not_pending}

  # Only one request can claim a given send; a lost claim reports the new wait.
  defp claim_send(user) do
    case SurrealStore.claim_verification_send(
           user["user_id"],
           user["verification_send_count"] || 0,
           now()
         ) do
      {:ok, claimed} when is_map(claimed) ->
        {:ok, claimed}

      {:ok, nil} ->
        case verification_status(user["user_id"]) do
          {:ok, %{status: "pending", resend_after_seconds: seconds}} when seconds > 0 ->
            {:error, {:too_soon, seconds}}

          {:ok, %{status: "pending"}} ->
            {:error, :verification_send_conflict}

          {:ok, %{status: "verified"}} ->
            {:error, :not_pending}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pending_user(user_id) do
    case SurrealStore.get_user(user_id) do
      {:ok, %{"status" => "pending_verification"} = user} -> {:ok, user}
      {:ok, _other} -> {:error, :not_pending}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resend_allowed(user) do
    case verification_of(user) do
      {:ok, %{resend_after_seconds: 0}} -> :ok
      {:ok, %{resend_after_seconds: seconds}} -> {:error, {:too_soon, seconds}}
    end
  end

  # Accounts created before the timed step have no send record and may resend now.
  defp verification_of(user) do
    {:ok,
     %{
       status: "pending",
       resend_after_seconds: seconds_until_resend(user),
       email_hint: email_hint(user["email"])
     }}
  end

  defp seconds_until_resend(%{"verification_sent_at" => sent_at} = user)
       when is_binary(sent_at) do
    config = RuntimeConfig.auth!()
    count = max(user["verification_send_count"] || 1, 1)

    wait =
      min(
        config.verification_resend_seconds * Integer.pow(2, min(count - 1, 16)),
        config.verification_resend_max_seconds
      )

    case DateTime.from_iso8601(sent_at) do
      {:ok, sent, _} -> max(wait - DateTime.diff(DateTime.utc_now(), sent, :second), 0)
      _ -> 0
    end
  end

  defp seconds_until_resend(_user), do: 0

  # Enough to recognise the address without repeating it in full.
  defp email_hint(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] -> String.first(local) <> "•••@" <> domain
      _ -> "•••"
    end
  end

  def issue_password_reset(email_input) do
    config = RuntimeConfig.auth!()

    with {:ok, email} <- normalize_email(email_input),
         {:ok, user} <- SurrealStore.find_user_by_email_key(email_key(email)),
         true <- is_map(user) && user["status"] == "active" do
      raw = random_token()

      record =
        token_record(
          token_hash(raw),
          user["user_id"],
          "reset_password",
          config.password_reset_ttl_seconds
        )

      case SurrealStore.create_token(record) do
        :ok -> {:ok, public_user(user), raw}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:ok, :not_applicable}
    end
  end

  def reset_password(raw_token, new_password)
      when is_binary(raw_token) and is_binary(new_password) do
    with :ok <- Password.validate(new_password),
         {:ok, token} <- valid_token(raw_token, "reset_password"),
         {:ok, password_hash} <- Password.hash(new_password),
         :ok <-
           SurrealStore.reset_password(
             token["user_id"],
             token["token_id"],
             password_hash,
             now()
           ) do
      :ok
    end
  end

  def reset_password(_, _), do: {:error, :invalid_request}

  @doc """
  The registered user for an email address, or nil when none exists.
  Read only; it never creates, verifies or changes an identity.
  """
  @spec find_user_by_email(term()) :: {:ok, map() | nil} | {:error, term()}
  def find_user_by_email(email_input) do
    with {:ok, email} <- normalize_email(email_input) do
      SurrealStore.find_user_by_email_key(email_key(email))
    end
  end

  def public_user(user) when is_map(user) do
    %{
      "user_id" => user["user_id"],
      "email" => user["email"],
      "display_name" => user["display_name"],
      "role" => user["role"],
      "status" => user["status"],
      "email_verified_at" => user["email_verified_at"]
    }
  end

  defp authenticate_user(nil, password, _user_agent) do
    Password.burn(password)
    {:error, :invalid_credentials}
  end

  defp authenticate_user(user, password, user_agent) when is_map(user) do
    cond do
      not Password.verify(password, user["password_hash"]) ->
        {:error, :invalid_credentials}

      user["status"] == "pending_verification" ->
        {:ok, verification} = verification_of(user)
        {:error, {:email_not_verified, Map.put(verification, :user_id, user["user_id"])}}

      user["status"] != "active" ->
        {:error, :account_disabled}

      true ->
        create_session(user, user_agent)
    end
  end

  defp create_session(user, user_agent) do
    config = RuntimeConfig.auth!()
    raw_token = random_token()
    csrf_token = random_token()
    created_at = now()
    expires_at = add_seconds(created_at, config.session_ttl_seconds)

    session = %{
      "session_id" => random_id(),
      "user_id" => user["user_id"],
      "token_hash" => token_hash(raw_token),
      "csrf_token" => csrf_token,
      "created_at" => created_at,
      "last_seen_at" => created_at,
      "expires_at" => expires_at,
      "revoked_at" => nil,
      "user_agent" => sanitize_user_agent(user_agent)
    }

    with {:ok, stored} <- SurrealStore.create_session(session) do
      {:ok,
       %{
         user: public_user(user),
         session: stored,
         raw_token: raw_token,
         csrf_token: csrf_token
       }}
    end
  end

  defp valid_token(raw_token, purpose) do
    token_id = token_hash(raw_token)

    with {:ok, token} <- SurrealStore.get_token(token_id),
         true <- is_map(token) || {:error, :invalid_token},
         true <- token["purpose"] == purpose || {:error, :invalid_token},
         true <- is_nil(token["consumed_at"]) || {:error, :invalid_token},
         {:ok, expires_at, _} <- DateTime.from_iso8601(token["expires_at"]),
         :gt <- DateTime.compare(expires_at, DateTime.utc_now()) do
      {:ok, token}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp token_record(token_id, user_id, purpose, ttl_seconds) do
    created_at = now()

    %{
      "token_id" => token_id,
      "user_id" => user_id,
      "purpose" => purpose,
      "created_at" => created_at,
      "expires_at" => add_seconds(created_at, ttl_seconds),
      "consumed_at" => nil
    }
  end

  defp normalize_email(value) when is_binary(value) do
    email = value |> String.trim() |> String.downcase()

    if String.length(email) <= 320 and Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email) do
      {:ok, email}
    else
      {:error, :invalid_email}
    end
  end

  defp normalize_email(_), do: {:error, :invalid_email}

  defp required_text(value, max) when is_binary(value) do
    normalized = String.trim(value)

    if normalized != "" and String.length(normalized) <= max do
      {:ok, normalized}
    else
      {:error, :invalid_request}
    end
  end

  defp required_text(_, _), do: {:error, :invalid_request}

  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, String.to_atom(key)))

  defp email_key(email), do: token_hash(email)
  defp token_hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp random_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp add_seconds(iso_now, seconds) do
    {:ok, dt, _} = DateTime.from_iso8601(iso_now)
    dt |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  defp sanitize_user_agent(nil), do: nil
  defp sanitize_user_agent(value) when is_binary(value), do: String.slice(value, 0, 512)
  defp sanitize_user_agent(_), do: nil
end
