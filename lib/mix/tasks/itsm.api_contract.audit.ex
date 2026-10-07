defmodule Mix.Tasks.Itsm.ApiContract.Audit do
  use Mix.Task

  @shortdoc "Audit standardized API CRUD/action and request-argument contracts"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    contracts = ItsmBackendWeb.ApiContract.audit!()

    Mix.shell().info("API Operation Contract v2")
    Mix.shell().info("=========================")
    Mix.shell().info("validated_routes: #{length(contracts)}")

    Enum.each(contracts, fn contract ->
      Mix.shell().info(
        "#{contract.method} #{contract.path} " <>
          "resource=#{contract.resource_type} " <>
          "operation=#{contract.operation_kind} " <>
          "effect=#{contract.effect} " <>
          "permission=#{contract.permission} " <>
          "path=#{inspect(contract.required_path_params)} " <>
          "body_required=#{inspect(contract.required_body_params)} " <>
          "body_optional=#{inspect(contract.optional_body_params)} " <>
          "query_required=#{inspect(contract.required_query_params)} " <>
          "query_optional=#{inspect(contract.optional_query_params)}"
      )
    end)
  end
end
