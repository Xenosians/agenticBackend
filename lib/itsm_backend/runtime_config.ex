defmodule ItsmBackend.RuntimeConfig do
  @moduledoc """
  Centralized validated access to deployment/runtime configuration.

  Deployment-specific values enter application code through this
  module instead of being fetched or defaulted throughout the
  business/runtime layers.

  Security invariants and protocol/domain policy do not belong here.
  """

  defmodule Error do
    @moduledoc false

    defexception [:message]
  end

  @ai_client_callbacks [
    {:run, 2},
    {:execute_job, 4},
    {:approve, 1},
    {:health, 0},
    {:ready, 0}
  ]

  @type queue_worker_config :: %{
          enabled: boolean(),
          poll_interval_ms: pos_integer(),
          lease_seconds: pos_integer()
        }

  @type ai_service_config :: %{
          base_url: String.t(),
          run_timeout_ms: pos_integer(),
          execute_timeout_ms: pos_integer(),
          health_timeout_ms: pos_integer(),
          ready_timeout_ms: pos_integer()
        }

  @type surrealdb_config :: %{
          url: String.t(),
          namespace: String.t(),
          database: String.t(),
          username: String.t(),
          password: String.t()
        }

  @type credential_vault_config :: %{
          key: binary(),
          key_version: String.t(),
          ttl_seconds: pos_integer()
        }

  # ------------------------------------------------------------
  # AI client
  # ------------------------------------------------------------

  @spec ai_client!() :: module()
  def ai_client! do
    case Application.fetch_env(
           :itsm_backend,
           :ai_client
         ) do
      {:ok, module}
      when is_atom(module) ->
        validate_ai_client_module!(module)

      {:ok, value} ->
        raise Error,
          message:
            "expected :itsm_backend.ai_client " <>
              "to be a module, got: " <>
              inspect(value)

      :error ->
        raise Error,
          message:
            "missing required runtime configuration " <>
              ":itsm_backend.ai_client"
    end
  end

  # ------------------------------------------------------------
  # Internal service authentication
  # ------------------------------------------------------------

  @spec internal_job_token!() :: String.t()
  def internal_job_token! do
    case Application.fetch_env(
           :itsm_backend,
           :internal_job_token
         ) do
      {:ok, token}
      when is_binary(token) ->
        if String.trim(token) == "" do
          raise Error,
            message:
              "expected :itsm_backend.internal_job_token " <>
                "to be a non-empty string"
        else
          token
        end

      {:ok, value} ->
        raise Error,
          message:
            "expected :itsm_backend.internal_job_token " <>
              "to be a string, got: " <>
              inspect(value)

      :error ->
        raise Error,
          message:
            "missing required runtime configuration " <>
              ":itsm_backend.internal_job_token"
    end
  end

  # ------------------------------------------------------------
  # DNS cluster
  #
  # DNS clustering is optional. Absence means clustering is
  # intentionally disabled for the current deployment.
  # ------------------------------------------------------------

  @spec dns_cluster_query!() ::
          String.t() | :ignore
  def dns_cluster_query! do
    case Application.fetch_env(
           :itsm_backend,
           :dns_cluster_query
         ) do
      :error ->
        :ignore

      {:ok, nil} ->
        :ignore

      {:ok, query}
      when is_binary(query) ->
        normalized =
          String.trim(query)

        if normalized == "" do
          raise Error,
            message:
              "expected :itsm_backend.dns_cluster_query " <>
                "to be a non-empty string when configured"
        else
          normalized
        end

      {:ok, value} ->
        raise Error,
          message:
            "expected :itsm_backend.dns_cluster_query " <>
              "to be a string or nil, got: " <>
              inspect(value)
    end
  end

  # ------------------------------------------------------------
  # CORS
  # ------------------------------------------------------------

  @spec cors_origins!() :: [String.t()]
  def cors_origins! do
    config =
      fetch_keyword_config!(:cors)

    case Keyword.fetch(
           config,
           :allowed_origins
         ) do
      {:ok, origins}
      when is_list(origins) and
             origins != [] ->
        origins
        |> Enum.map(&validate_cors_origin!/1)
        |> Enum.uniq()

      {:ok, []} ->
        raise Error,
          message:
            "expected :itsm_backend.cors.allowed_origins " <>
              "to contain at least one origin"

      {:ok, value} ->
        raise Error,
          message:
            "expected :itsm_backend.cors.allowed_origins " <>
              "to be a non-empty list, got: " <>
              inspect(value)

      :error ->
        raise_missing_field!(
          :cors,
          :allowed_origins
        )
    end
  end

  # ------------------------------------------------------------
  # Queue worker
  # ------------------------------------------------------------

  @spec queue_worker!() :: queue_worker_config()
  def queue_worker! do
    config =
      fetch_keyword_config!(:queue_worker)

    %{
      enabled:
        fetch_boolean!(
          config,
          :enabled,
          :queue_worker
        ),
      poll_interval_ms:
        fetch_positive_integer!(
          config,
          :poll_interval_ms,
          :queue_worker
        ),
      lease_seconds:
        fetch_positive_integer!(
          config,
          :lease_seconds,
          :queue_worker
        )
    }
  end

  # ------------------------------------------------------------
  # AI service
  # ------------------------------------------------------------

  @spec ai_service!() :: ai_service_config()
  def ai_service! do
    config =
      fetch_keyword_config!(:ai_service)

    %{
      base_url:
        fetch_http_url!(
          config,
          :base_url,
          :ai_service
        ),
      run_timeout_ms:
        fetch_positive_integer!(
          config,
          :run_timeout_ms,
          :ai_service
        ),
      execute_timeout_ms:
        fetch_positive_integer!(
          config,
          :execute_timeout_ms,
          :ai_service
        ),
      health_timeout_ms:
        fetch_positive_integer!(
          config,
          :health_timeout_ms,
          :ai_service
        ),
      ready_timeout_ms:
        fetch_positive_integer!(
          config,
          :ready_timeout_ms,
          :ai_service
        )
    }
  end

  # ------------------------------------------------------------
  # SurrealDB
  # ------------------------------------------------------------

  @spec surrealdb!() :: surrealdb_config()
  def surrealdb! do
    config =
      fetch_keyword_config!(:surrealdb)

    %{
      url:
        fetch_http_url!(
          config,
          :url,
          :surrealdb
        ),
      namespace:
        fetch_non_empty_string!(
          config,
          :namespace,
          :surrealdb
        ),
      database:
        fetch_non_empty_string!(
          config,
          :database,
          :surrealdb
        ),
      username:
        fetch_non_empty_string!(
          config,
          :username,
          :surrealdb
        ),
      password:
        fetch_secret_string!(
          config,
          :password,
          :surrealdb
        )
    }
  end

  # ------------------------------------------------------------
  # Credential vault
  # ------------------------------------------------------------

  @spec credential_vault!() :: credential_vault_config()
  def credential_vault! do
    config =
      fetch_keyword_config!(:credential_vault)

    key_b64 =
      fetch_secret_string!(
        config,
        :key_b64,
        :credential_vault
      )

    key =
      case Base.decode64(key_b64) do
        {:ok, decoded}
        when byte_size(decoded) == 32 ->
          decoded

        {:ok, _decoded} ->
          raise Error,
            message:
              "expected :itsm_backend.credential_vault.key_b64 " <>
                "to decode to exactly 32 bytes"

        :error ->
          raise Error,
            message:
              "expected :itsm_backend.credential_vault.key_b64 " <>
                "to contain valid base64"
      end

    %{
      key: key,
      key_version:
        fetch_non_empty_string!(
          config,
          :key_version,
          :credential_vault
        ),
      ttl_seconds:
        fetch_positive_integer!(
          config,
          :ttl_seconds,
          :credential_vault
        )
    }
  end

  # ------------------------------------------------------------
  # Browser application authentication
  # ------------------------------------------------------------

  @spec auth!() :: map()
  def auth! do
    config = fetch_keyword_config!(:auth)

    admin_emails =
      case Keyword.get(config, :admin_emails, []) do
        values when is_list(values) ->
          values
          |> Enum.map(fn value ->
            if is_binary(value), do: value |> String.trim() |> String.downcase(), else: ""
          end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        value ->
          raise Error,
            message:
              "expected :itsm_backend.auth.admin_emails to be a list, got: #{inspect(value)}"
      end

    cookie_same_site =
      fetch_non_empty_string!(config, :cookie_same_site, :auth)

    if cookie_same_site not in ["Lax", "Strict", "None"] do
      raise Error,
        message: "expected :itsm_backend.auth.cookie_same_site to be Lax, Strict, or None"
    end

    cookie_secure = fetch_boolean!(config, :cookie_secure, :auth)

    if cookie_same_site == "None" and not cookie_secure do
      raise Error, message: "SameSite=None requires a secure authentication cookie"
    end

    %{
      registration_enabled: fetch_boolean!(config, :registration_enabled, :auth),
      session_ttl_seconds: fetch_positive_integer!(config, :session_ttl_seconds, :auth),
      verification_ttl_seconds: fetch_positive_integer!(config, :verification_ttl_seconds, :auth),
      password_reset_ttl_seconds:
        fetch_positive_integer!(config, :password_reset_ttl_seconds, :auth),
      cookie_name: fetch_non_empty_string!(config, :cookie_name, :auth),
      cookie_secure: cookie_secure,
      cookie_same_site: cookie_same_site,
      frontend_base_url: fetch_http_url!(config, :frontend_base_url, :auth),
      mail_from_email: fetch_non_empty_string!(config, :mail_from_email, :auth),
      mail_from_name: fetch_non_empty_string!(config, :mail_from_name, :auth),
      admin_emails: admin_emails,
      ai_context_enabled: fetch_boolean!(config, :ai_context_enabled, :auth),
      ai_context_max_turns: fetch_positive_integer!(config, :ai_context_max_turns, :auth)
    }
  end

  # ------------------------------------------------------------
  # CORS validation
  # ------------------------------------------------------------

  defp validate_cors_origin!(origin)
       when is_binary(origin) do
    normalized =
      String.trim(origin)

    uri =
      URI.parse(normalized)

    valid_path? =
      uri.path in [
        nil,
        "",
        "/"
      ]

    if uri.scheme in [
         "http",
         "https"
       ] and
         is_binary(uri.host) and
         uri.host != "" and
         is_nil(uri.userinfo) and
         is_nil(uri.query) and
         is_nil(uri.fragment) and
         valid_path? do
      String.trim_trailing(
        normalized,
        "/"
      )
    else
      raise Error,
        message:
          "expected :itsm_backend.cors.allowed_origins " <>
            "entries to be HTTP(S) origins without paths, " <>
            "queries, fragments, or credentials, got: " <>
            inspect(origin)
    end
  end

  defp validate_cors_origin!(origin) do
    raise Error,
      message:
        "expected :itsm_backend.cors.allowed_origins " <>
          "entries to be strings, got: " <>
          inspect(origin)
  end

  # ------------------------------------------------------------
  # AI client validation
  # ------------------------------------------------------------

  defp validate_ai_client_module!(module) do
    if Code.ensure_loaded?(module) and
         Enum.all?(
           @ai_client_callbacks,
           fn {function, arity} ->
             function_exported?(
               module,
               function,
               arity
             )
           end
         ) do
      module
    else
      raise Error,
        message:
          "expected :itsm_backend.ai_client " <>
            "to implement the ItsmBackend.AIClient contract, got: " <>
            inspect(module)
    end
  end

  # ------------------------------------------------------------
  # Root application config
  # ------------------------------------------------------------

  defp fetch_keyword_config!(config_key) do
    case Application.fetch_env(
           :itsm_backend,
           config_key
         ) do
      {:ok, config}
      when is_list(config) ->
        if Keyword.keyword?(config) do
          config
        else
          raise Error,
            message:
              invalid_container_message(
                config_key,
                config
              )
        end

      {:ok, config} ->
        raise Error,
          message:
            invalid_container_message(
              config_key,
              config
            )

      :error ->
        raise Error,
          message:
            "missing required runtime configuration " <>
              inspect_config_path(config_key)
    end
  end

  # ------------------------------------------------------------
  # Typed values
  # ------------------------------------------------------------

  defp fetch_boolean!(
         config,
         field,
         config_key
       ) do
    case Keyword.fetch(
           config,
           field
         ) do
      {:ok, value}
      when is_boolean(value) ->
        value

      {:ok, value}
      when is_binary(value) ->
        parse_boolean!(
          value,
          config_key,
          field
        )

      {:ok, value} ->
        raise_invalid_boolean!(
          config_key,
          field,
          value
        )

      :error ->
        raise_missing_field!(
          config_key,
          field
        )
    end
  end

  defp parse_boolean!(
         value,
         config_key,
         field
       ) do
    case value
         |> String.trim()
         |> String.downcase() do
      "true" ->
        true

      "false" ->
        false

      _ ->
        raise_invalid_boolean!(
          config_key,
          field,
          value
        )
    end
  end

  defp raise_invalid_boolean!(
         config_key,
         field,
         value
       ) do
    raise Error,
      message:
        "expected " <>
          inspect_config_path(
            config_key,
            field
          ) <>
          " to be a boolean, got: " <>
          inspect(value)
  end

  defp fetch_positive_integer!(
         config,
         field,
         config_key
       ) do
    case Keyword.fetch(
           config,
           field
         ) do
      {:ok, value}
      when is_integer(value) and
             value > 0 ->
        value

      {:ok, value}
      when is_binary(value) ->
        parse_positive_integer!(
          value,
          config_key,
          field
        )

      {:ok, value} ->
        raise_invalid_positive_integer!(
          config_key,
          field,
          value
        )

      :error ->
        raise_missing_field!(
          config_key,
          field
        )
    end
  end

  defp parse_positive_integer!(
         value,
         config_key,
         field
       ) do
    normalized =
      String.trim(value)

    case Integer.parse(normalized) do
      {integer, ""}
      when integer > 0 ->
        integer

      _ ->
        raise_invalid_positive_integer!(
          config_key,
          field,
          value
        )
    end
  end

  defp raise_invalid_positive_integer!(
         config_key,
         field,
         value
       ) do
    raise Error,
      message:
        "expected " <>
          inspect_config_path(
            config_key,
            field
          ) <>
          " to be a positive integer, got: " <>
          inspect(value)
  end

  defp fetch_non_empty_string!(
         config,
         field,
         config_key
       ) do
    case Keyword.fetch(
           config,
           field
         ) do
      {:ok, value}
      when is_binary(value) ->
        normalized =
          String.trim(value)

        if normalized == "" do
          raise Error,
            message:
              "expected " <>
                inspect_config_path(
                  config_key,
                  field
                ) <>
                " to be a non-empty string"
        else
          normalized
        end

      {:ok, value} ->
        raise Error,
          message:
            "expected " <>
              inspect_config_path(
                config_key,
                field
              ) <>
              " to be a string, got: " <>
              inspect(value)

      :error ->
        raise_missing_field!(
          config_key,
          field
        )
    end
  end

  defp fetch_secret_string!(
         config,
         field,
         config_key
       ) do
    case Keyword.fetch(
           config,
           field
         ) do
      {:ok, value}
      when is_binary(value) ->
        if String.trim(value) == "" do
          raise Error,
            message:
              "expected " <>
                inspect_config_path(
                  config_key,
                  field
                ) <>
                " to be a non-empty string"
        else
          value
        end

      {:ok, value} ->
        raise Error,
          message:
            "expected " <>
              inspect_config_path(
                config_key,
                field
              ) <>
              " to be a string, got: " <>
              inspect(value)

      :error ->
        raise_missing_field!(
          config_key,
          field
        )
    end
  end

  defp fetch_http_url!(
         config,
         field,
         config_key
       ) do
    value =
      fetch_non_empty_string!(
        config,
        field,
        config_key
      )

    uri =
      URI.parse(value)

    if uri.scheme in [
         "http",
         "https"
       ] and
         is_binary(uri.host) and
         uri.host != "" and
         is_nil(uri.query) and
         is_nil(uri.fragment) do
      String.trim_trailing(
        value,
        "/"
      )
    else
      raise Error,
        message:
          "expected " <>
            inspect_config_path(
              config_key,
              field
            ) <>
            " to be an HTTP(S) base URL, got: " <>
            inspect(value)
    end
  end

  # ------------------------------------------------------------
  # Errors
  # ------------------------------------------------------------

  defp raise_missing_field!(
         config_key,
         field
       ) do
    raise Error,
      message:
        "missing required runtime configuration " <>
          inspect_config_path(
            config_key,
            field
          )
  end

  defp invalid_container_message(
         config_key,
         value
       ) do
    "expected " <>
      inspect_config_path(config_key) <>
      " to be a keyword list, got: " <>
      inspect(value)
  end

  defp inspect_config_path(config_key) do
    ":itsm_backend." <>
      Atom.to_string(config_key)
  end

  defp inspect_config_path(
         config_key,
         field
       ) do
    inspect_config_path(config_key) <>
      "." <>
      Atom.to_string(field)
  end
end
