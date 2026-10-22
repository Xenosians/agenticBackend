defmodule ItsmBackend.Surreal.Bindings do
  @moduledoc """
  Exact JSON parameter binding for SurrealDB's coercing JSON RPC decoder.

  Only actual parameter tokens are replaced by bounded JSON decode expressions.
  Query literals, comments, local variables and the caller's result entries stay
  intact. Trusted datetime values are cast explicitly; ISO-looking user text is
  never inferred to be a date. Validation completes before any database request.
  """

  alias ItsmBackend.Surreal.DateTimeValue

  @max_depth 64
  @integer_min -9_223_372_036_854_775_808
  @integer_max 9_223_372_036_854_775_807
  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  def bind(statement, params) when is_binary(statement) and is_map(params) do
    with {:ok, tokens} <- tokenize(statement, []),
         {:ok, bindings, values} <- encode_parameters(params, unused_prefix(statement)),
         {:ok, rewritten} <- rewrite(tokens, bindings) do
      {:ok, rewritten, values}
    else
      {:error, reason} -> {:error, {:invalid_surreal_parameters, reason}}
    end
  end

  def bind(_, _), do: {:error, {:invalid_surreal_parameters, :invalid_query_parameters}}

  defp unused_prefix(statement, prefix \\ "__itsm_bound_") do
    if String.contains?(statement, "$" <> prefix),
      do: unused_prefix(statement, prefix <> "_"),
      else: prefix
  end

  defp encode_parameters(params, prefix) do
    params
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, %{}}, fn {{key, value}, index}, {:ok, bindings, values} ->
      with true <- is_binary(key) and Regex.match?(@identifier, key),
           {:ok, normalized} <- normalize(value, 0),
           {:ok, encoded} <- Jason.encode(normalized),
           variable = prefix <> Integer.to_string(index),
           base = "encoding::json::decode($" <> variable <> ")",
           {:ok, expression} <- typed_expression(value, base) do
        {:cont,
         {:ok, Map.put(bindings, key, "(" <> expression <> ")"),
          Map.put(values, variable, encoded)}}
      else
        false -> {:halt, {:error, :invalid_parameter_name}}
        {:error, reason} when is_atom(reason) -> {:halt, {:error, reason}}
        {:error, _} -> {:halt, {:error, :json_encoding_failed}}
      end
    end)
  end

  defp normalize(_, depth) when depth > @max_depth, do: {:error, :nesting_limit}
  defp normalize(nil, _), do: {:ok, nil}
  defp normalize(value, _) when is_boolean(value), do: {:ok, value}

  defp normalize(value, _) when is_integer(value) do
    if value >= @integer_min and value <= @integer_max,
      do: {:ok, value},
      else: {:error, :integer_out_of_range}
  end

  defp normalize(value, _) when is_float(value), do: {:ok, value}

  defp normalize(value, _) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_utf8}
  end

  defp normalize(%DateTimeValue{value: value}, _), do: normalize_datetime(value)
  defp normalize(%DateTime{} = value, _), do: normalize_datetime(value)
  defp normalize(%_{} = _value, _), do: {:error, :unsupported_parameter_type}

  defp normalize(value, depth) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, result} ->
      with true <- is_binary(key) and String.valid?(key),
           {:ok, normalized} <- normalize(item, depth + 1) do
        {:cont, {:ok, Map.put(result, key, normalized)}}
      else
        false -> {:halt, {:error, :invalid_map_key}}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize(value, depth) when is_list(value), do: normalize_list(value, depth, [])

  defp normalize(_, _), do: {:error, :unsupported_parameter_type}

  defp normalize_list([], _, result), do: {:ok, Enum.reverse(result)}

  defp normalize_list([item | tail], depth, result) do
    with {:ok, normalized} <- normalize(item, depth + 1),
         do: normalize_list(tail, depth, [normalized | result])
  end

  defp normalize_list(_, _, _), do: {:error, :unsupported_parameter_type}

  defp normalize_datetime(%DateTime{} = datetime) do
    normalize_datetime(DateTime.to_iso8601(datetime))
  rescue
    _ -> {:error, :invalid_datetime}
  end

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_iso8601(datetime)}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp normalize_datetime(_), do: {:error, :invalid_datetime}

  defp typed_expression(%DateTimeValue{}, base), do: {:ok, "<datetime>(" <> base <> ")"}
  defp typed_expression(%DateTime{}, base), do: {:ok, "<datetime>(" <> base <> ")"}

  defp typed_expression(value, base) when is_map(value) do
    value
    |> Enum.filter(fn {_key, item} -> contains_datetime?(item) end)
    |> Enum.reduce_while({:ok, []}, fn {key, item}, {:ok, fields} ->
      with true <- Regex.match?(@identifier, key),
           {:ok, expression} <- typed_expression(item, base <> ".`" <> key <> "`") do
        {:cont, {:ok, ["`" <> key <> "`: " <> expression | fields]}}
      else
        false -> {:halt, {:error, :unsupported_datetime_field}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} ->
        {:ok, base}

      {:ok, fields} ->
        {:ok, "object::extend(" <> base <> ", {" <> Enum.join(fields, ", ") <> "})"}

      error ->
        error
    end
  end

  defp typed_expression(value, base) when is_list(value) do
    if contains_datetime?(value) do
      value
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, fields} ->
        case typed_expression(item, base <> "[" <> Integer.to_string(index) <> "]") do
          {:ok, expression} -> {:cont, {:ok, [expression | fields]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, fields} -> {:ok, "[" <> (fields |> Enum.reverse() |> Enum.join(", ")) <> "]"}
        error -> error
      end
    else
      {:ok, base}
    end
  end

  defp typed_expression(_, base), do: {:ok, base}

  defp contains_datetime?(%DateTimeValue{}), do: true
  defp contains_datetime?(%DateTime{}), do: true

  defp contains_datetime?(value) when is_map(value),
    do: Enum.any?(value, fn {_, item} -> contains_datetime?(item) end)

  defp contains_datetime?(value) when is_list(value), do: Enum.any?(value, &contains_datetime?/1)
  defp contains_datetime?(_), do: false

  # The lexer retains exact original bytes; only parameter tokens enter rewriting.
  defp tokenize("", tokens), do: {:ok, Enum.reverse(tokens)}

  defp tokenize("/*" <> rest, tokens) do
    with {:ok, comment, tail} <- block_comment(rest, 1, ["/*"]) do
      tokenize(tail, [{:ignored, comment} | tokens])
    end
  end

  defp tokenize(<<a, b, rest::binary>>, tokens) when {a, b} in [{?-, ?-}, {?/, ?/}] do
    {text, tail} = line_comment(rest, [<<a, b>>])
    tokenize(tail, [{:ignored, text} | tokens])
  end

  defp tokenize("#" <> rest, tokens) do
    {text, tail} = line_comment(rest, ["#"])
    tokenize(tail, [{:ignored, text} | tokens])
  end

  defp tokenize(<<quote, rest::binary>>, tokens) when quote in [?', ?", ?`] do
    with {:ok, text, tail} <- quoted(rest, <<quote>>, [<<quote>>]) do
      tokenize(tail, [{:literal, text} | tokens])
    end
  end

  defp tokenize("⟨" <> rest, tokens) do
    with {:ok, text, tail} <- quoted(rest, "⟩", ["⟨"]) do
      tokenize(tail, [{:literal, text} | tokens])
    end
  end

  defp tokenize("$" <> <<first, _::binary>> = text, tokens)
       when first in ?a..?z or first in ?A..?Z or first == ?_ do
    <<?$, rest::binary>> = text
    {name, tail} = identifier(rest, [])
    tokenize(tail, [{:parameter, name} | tokens])
  end

  defp tokenize(<<first, _::binary>> = text, tokens)
       when first in ?a..?z or first in ?A..?Z or first == ?_ do
    {word, tail} = identifier(text, [])
    tokenize(tail, [{:word, word} | tokens])
  end

  defp tokenize(<<space, rest::binary>>, tokens) when space in [?\s, ?\n, ?\r, ?\t] do
    tokenize(rest, [{:ignored, <<space>>} | tokens])
  end

  defp tokenize(<<symbol, rest::binary>>, tokens),
    do: tokenize(rest, [{:symbol, <<symbol>>} | tokens])

  defp identifier(<<char, rest::binary>>, parts)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char == ?_ do
    identifier(rest, [<<char>> | parts])
  end

  defp identifier(rest, parts), do: {parts |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  defp line_comment("", parts), do: {parts |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp line_comment("\n" <> rest, parts),
    do: {parts |> Enum.reverse() |> IO.iodata_to_binary(), "\n" <> rest}

  defp line_comment(<<char, rest::binary>>, parts), do: line_comment(rest, [<<char>> | parts])

  defp block_comment("", _, _), do: {:error, :unterminated_query_comment}

  defp block_comment("/*" <> rest, depth, parts),
    do: block_comment(rest, depth + 1, ["/*" | parts])

  defp block_comment("*/" <> rest, 1, parts),
    do: {:ok, ["*/" | parts] |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp block_comment("*/" <> rest, depth, parts),
    do: block_comment(rest, depth - 1, ["*/" | parts])

  defp block_comment(<<char, rest::binary>>, depth, parts),
    do: block_comment(rest, depth, [<<char>> | parts])

  defp quoted("", _, _), do: {:error, :unterminated_query_literal}

  defp quoted(<<92, escaped, rest::binary>>, delimiter, parts),
    do: quoted(rest, delimiter, [<<92, escaped>> | parts])

  defp quoted(text, delimiter, parts) do
    if String.starts_with?(text, delimiter) do
      size = byte_size(delimiter)
      rest = binary_part(text, size, byte_size(text) - size)
      {:ok, [delimiter | parts] |> Enum.reverse() |> IO.iodata_to_binary(), rest}
    else
      <<char, rest::binary>> = text
      quoted(rest, delimiter, [<<char>> | parts])
    end
  end

  defp rewrite(tokens, bindings) do
    state = %{scopes: [%{locals: MapSet.new(), pending: []}], let?: false, output: []}

    final = Enum.reduce(tokens, state, &rewrite_token(&1, &2, bindings))
    {:ok, final.output |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp rewrite_token({:ignored, text}, state, _), do: emit(state, text)

  defp rewrite_token({:word, text}, state, _) do
    %{emit(state, text) | let?: String.upcase(text) == "LET"}
  end

  defp rewrite_token({:parameter, name}, %{let?: true} = state, _) do
    [scope | outer] = state.scopes

    %{
      emit(state, "$" <> name)
      | let?: false,
        scopes: [%{scope | pending: [name | scope.pending]} | outer]
    }
  end

  defp rewrite_token({:parameter, name}, state, bindings) do
    local? = Enum.any?(state.scopes, &MapSet.member?(&1.locals, name))
    text = if local?, do: "$" <> name, else: Map.get(bindings, name, "$" <> name)
    %{emit(state, text) | let?: false}
  end

  defp rewrite_token({:symbol, ";"}, state, _) do
    [scope | outer] = state.scopes
    scope = %{locals: Enum.reduce(scope.pending, scope.locals, &MapSet.put(&2, &1)), pending: []}
    %{emit(state, ";") | let?: false, scopes: [scope | outer]}
  end

  defp rewrite_token({:symbol, "{"}, state, _) do
    %{
      emit(state, "{")
      | let?: false,
        scopes: [%{locals: MapSet.new(), pending: []} | state.scopes]
    }
  end

  defp rewrite_token({:symbol, "}"}, %{scopes: [_scope, parent | outer]} = state, _) do
    %{emit(state, "}") | let?: false, scopes: [parent | outer]}
  end

  defp rewrite_token({_kind, text}, state, _), do: %{emit(state, text) | let?: false}
  defp emit(state, text), do: %{state | output: [text | state.output]}
end
