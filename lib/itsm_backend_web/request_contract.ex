defmodule ItsmBackendWeb.RequestContract do
  @moduledoc """
  Declarative request-argument contract for Phoenix controller actions.

  This is application/API metadata, not AI policy and not a runtime branch on
  controller names. Each controller action declares the arguments accepted at
  its own boundary while the router remains authoritative for path parameters.
  """

  defmacro __using__(_opts) do
    quote do
      import ItsmBackendWeb.RequestContract,
        only: [request_contract: 2]

      Module.register_attribute(
        __MODULE__,
        :request_contracts,
        accumulate: true
      )

      @before_compile ItsmBackendWeb.RequestContract
    end
  end

  defmacro request_contract(action, opts) do
    quote do
      @request_contracts {
        unquote(action),
        Map.new(unquote(opts))
      }
    end
  end

  defmacro __before_compile__(env) do
    pairs =
      env.module
      |> Module.get_attribute(:request_contracts)
      |> Enum.reverse()

    actions = Enum.map(pairs, fn {action, _contract} -> action end)

    if length(actions) != length(Enum.uniq(actions)) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "duplicate request_contract action in #{inspect(env.module)}"
    end

    contracts = Map.new(pairs)
    escaped = Macro.escape(contracts)

    quote do
      @doc false
      def __request_contract__(action) do
        Map.get(unquote(escaped), action)
      end

      @doc false
      def __request_contracts__ do
        unquote(escaped)
      end
    end
  end
end
