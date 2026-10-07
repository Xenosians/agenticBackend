defmodule ItsmBackendWeb.ApiContract do
  @moduledoc """
  Standard API operation contract for every Phoenix `/api...` route.

  CRUD/search/action semantics are derived from the HTTP/router boundary.
  Path arguments are derived from the route. Body/query arguments are declared
  by the controller action through `ItsmBackendWeb.RequestContract`.

  This module audits application semantics only. Authentication, RBAC/ABAC,
  policy, CSRF, approval and execution remain owned by their existing layers.
  """

  defmodule Contract do
    @enforce_keys [
      :method,
      :path,
      :controller,
      :action,
      :resource_type,
      :operation_kind,
      :effect,
      :permission,
      :required_path_params,
      :required_body_params,
      :optional_body_params,
      :required_query_params,
      :optional_query_params,
      :argument_contract_source
    ]

    defstruct [
      :method,
      :path,
      :controller,
      :action,
      :resource_type,
      :operation_kind,
      :effect,
      :permission,
      :required_path_params,
      :required_body_params,
      :optional_body_params,
      :required_query_params,
      :optional_query_params,
      :argument_contract_source
    ]
  end

  @operation_kinds ~w(create read update delete search action)
  @effects ~w(read mutation)

  def contracts(router \\ ItsmBackendWeb.Router) do
    router
    |> raw_routes()
    |> Enum.filter(&api_route?/1)
    |> Enum.map(&from_route/1)
  end

  def audit!(router \\ ItsmBackendWeb.Router) do
    contracts = contracts(router)
    Enum.each(contracts, &validate!/1)
    contracts
  end

  def from_route(route) do
    method = normalize_method(Map.get(route, :verb))
    path = Map.get(route, :path) || ""
    controller_module = Map.get(route, :plug)
    action_atom = Map.get(route, :plug_opts)
    controller = controller_name(controller_module)
    action = action_name(action_atom)
    request = request_contract!(controller_module, action_atom)

    default_resource = resource_from_controller(controller)
    default_operation = operation_kind(method, action)
    default_effect = effect_for(method)

    resource_type =
      request
      |> Map.get(:resource_type, default_resource)
      |> normalize_nonempty_string(:resource_type, path)

    operation_kind =
      request
      |> Map.get(:operation_kind, default_operation)
      |> normalize_atom_or_string(:operation_kind, path)

    effect =
      request
      |> Map.get(:effect, default_effect)
      |> normalize_atom_or_string(:effect, path)

    permission =
      request
      |> Map.get(:permission, permission(resource_type, operation_kind))
      |> normalize_nonempty_string(:permission, path)

    %Contract{
      method: method,
      path: path,
      controller: controller,
      action: action,
      resource_type: resource_type,
      operation_kind: operation_kind,
      effect: effect,
      permission: permission,
      required_path_params: path_params(path),
      required_body_params: contract_list(request, :required_body, path),
      optional_body_params: contract_list(request, :optional_body, path),
      required_query_params: contract_list(request, :required_query, path),
      optional_query_params: contract_list(request, :optional_query, path),
      argument_contract_source: "controller_request_contract_v1"
    }
  end

  defp request_contract!(controller, action)
       when is_atom(controller) and is_atom(action) do
    Code.ensure_loaded(controller)

    unless function_exported?(controller, :__request_contract__, 1) do
      raise "Controller #{inspect(controller)} does not declare RequestContract metadata"
    end

    case controller.__request_contract__(action) do
      value when is_map(value) -> value
      nil -> raise "Missing request contract for #{inspect(controller)}.#{action}/2"
      other -> raise "Invalid request contract for #{inspect(controller)}.#{action}/2: #{inspect(other)}"
    end
  end

  defp request_contract!(controller, action) do
    raise "Invalid Phoenix controller/action contract: #{inspect(controller)} #{inspect(action)}"
  end

  defp contract_list(contract, key, path) do
    value = Map.get(contract, key, [])

    unless is_list(value) do
      raise "#{key} must be a list for #{path}"
    end

    normalized =
      Enum.map(value, fn
        item when is_binary(item) ->
          item = String.trim(item)
          if item == "", do: raise("empty #{key} entry for #{path}"), else: item

        item ->
          raise "non-string #{key} entry for #{path}: #{inspect(item)}"
      end)

    if length(normalized) != length(Enum.uniq(normalized)) do
      raise "duplicate #{key} entries for #{path}"
    end

    normalized
  end

  defp raw_routes(router) do
    Code.ensure_loaded(router)

    cond do
      function_exported?(router, :__routes__, 0) ->
        router.__routes__()

      Code.ensure_loaded?(Phoenix.Router) and
          function_exported?(Phoenix.Router, :routes, 1) ->
        Phoenix.Router.routes(router)

      true ->
        raise "Unable to enumerate Phoenix routes for #{inspect(router)}"
    end
  end

  defp api_route?(route) do
    path = Map.get(route, :path) || ""
    String.starts_with?(path, "/api")
  end

  defp normalize_method(method) when is_binary(method), do: String.upcase(method)
  defp normalize_method(method) when is_atom(method), do: method |> Atom.to_string() |> String.upcase()
  defp normalize_method(method), do: method |> to_string() |> String.upcase()

  defp controller_name(controller) when is_atom(controller) do
    controller |> Module.split() |> List.last()
  end

  defp controller_name(controller), do: to_string(controller)

  defp action_name(action) when is_atom(action), do: Atom.to_string(action)
  defp action_name(action) when is_binary(action), do: action
  defp action_name(action), do: to_string(action)

  defp resource_from_controller(controller) do
    controller
    |> String.replace_suffix("Controller", "")
    |> Macro.underscore()
    |> normalize_resource_alias()
  end

  defp normalize_resource_alias("health"), do: "system"
  defp normalize_resource_alias("job_completion"), do: "job"
  defp normalize_resource_alias("job_heartbeat"), do: "job"
  defp normalize_resource_alias(resource), do: resource

  defp operation_kind("GET", "index"), do: "search"
  defp operation_kind("GET", _action), do: "read"
  defp operation_kind("POST", action) when action in ["create", "register"], do: "create"
  defp operation_kind("PUT", _action), do: "update"
  defp operation_kind("PATCH", _action), do: "update"
  defp operation_kind("DELETE", _action), do: "delete"
  defp operation_kind("POST", _action), do: "action"
  defp operation_kind(_method, _action), do: "action"

  defp effect_for("GET"), do: "read"
  defp effect_for(_method), do: "mutation"

  defp permission(resource_type, operation_kind), do: resource_type <> "." <> operation_kind

  defp path_params(path) do
    Regex.scan(~r/:([A-Za-z0-9_]+)/, path)
    |> Enum.map(fn [_match, name] -> name end)
  end

  defp normalize_atom_or_string(value, field, path) when is_atom(value) do
    value |> Atom.to_string() |> normalize_nonempty_string(field, path)
  end

  defp normalize_atom_or_string(value, field, path) do
    normalize_nonempty_string(value, field, path)
  end

  defp normalize_nonempty_string(value, field, path) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized == "", do: raise("empty #{field} for #{path}"), else: normalized
  end

  defp normalize_nonempty_string(value, field, path) do
    raise "invalid #{field} for #{path}: #{inspect(value)}"
  end

  def validate!(%Contract{} = contract) do
    unless contract.operation_kind in @operation_kinds do
      raise "Invalid operation_kind #{inspect(contract.operation_kind)} for #{contract.path}"
    end

    unless contract.effect in @effects do
      raise "Invalid effect #{inspect(contract.effect)} for #{contract.path}"
    end

    if contract.effect == "read" and contract.method != "GET" do
      raise "Non-GET route cannot have read effect: #{contract.method} #{contract.path}"
    end

    if contract.effect == "mutation" and contract.method == "GET" do
      raise "GET route cannot have mutation effect: #{contract.path}"
    end

    if contract.effect == "read" and contract.operation_kind in ["create", "update", "delete"] do
      raise "Read route has mutating operation_kind=#{contract.operation_kind}: #{contract.path}"
    end

    if contract.effect == "mutation" and contract.operation_kind in ["read", "search"] do
      raise "Mutation route has read operation_kind=#{contract.operation_kind}: #{contract.path}"
    end

    unless String.contains?(contract.permission, ".") do
      raise "Invalid permission #{inspect(contract.permission)} for #{contract.path}"
    end

    validate_argument_partition!(contract.required_body_params, contract.optional_body_params, "body", contract.path)
    validate_argument_partition!(contract.required_query_params, contract.optional_query_params, "query", contract.path)

    :ok
  end

  defp validate_argument_partition!(required, optional, source, path) do
    overlap = MapSet.intersection(MapSet.new(required), MapSet.new(optional)) |> MapSet.to_list()

    if overlap != [] do
      raise "#{source} required/optional overlap for #{path}: #{inspect(overlap)}"
    end
  end
end
