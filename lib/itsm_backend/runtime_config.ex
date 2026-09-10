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

  @type queue_worker_config :: %{
          enabled: boolean(),
          poll_interval_ms: pos_integer(),
          lease_seconds: pos_integer()
        }

  # ------------------------------------------------------------
  # Queue worker
  # ------------------------------------------------------------

  @spec queue_worker!() ::
          queue_worker_config()
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

      {:ok, value} ->
        raise Error,
          message:
            "expected " <>
              inspect_config_path(
                config_key,
                field
              ) <>
              " to be a boolean, got: " <>
              inspect(value)

      :error ->
        raise_missing_field!(
          config_key,
          field
        )
    end
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

      {:ok, value} ->
        raise Error,
          message:
            "expected " <>
              inspect_config_path(
                config_key,
                field
              ) <>
              " to be a positive integer, got: " <>
              inspect(value)

      :error ->
        raise_missing_field!(
          config_key,
          field
        )
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
