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
