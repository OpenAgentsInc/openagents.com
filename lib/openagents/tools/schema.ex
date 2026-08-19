defmodule OpenAgents.Tools.Schema do
  @moduledoc false

  @maximum_depth 8
  @maximum_properties 64

  @spec validate_schema(term()) :: :ok | {:error, atom()}
  def validate_schema(schema), do: validate_schema(schema, 0)

  @spec validate_value(term(), map()) :: :ok | {:error, atom()}
  def validate_value(value, schema), do: validate_value(value, schema, 0)

  defp validate_schema(_schema, depth) when depth > @maximum_depth,
    do: {:error, :schema_too_deep}

  defp validate_schema(%{"type" => "object", "properties" => properties} = schema, depth)
       when is_map(properties) and map_size(properties) <= @maximum_properties do
    required = Map.get(schema, "required", [])

    cond do
      Map.get(schema, "additionalProperties", false) not in [true, false] ->
        {:error, :invalid_schema}

      not is_list(required) or not Enum.all?(required, &is_binary/1) ->
        {:error, :invalid_schema}

      not Enum.all?(required, &Map.has_key?(properties, &1)) ->
        {:error, :invalid_schema}

      true ->
        validate_child_schemas(properties, depth)
    end
  end

  defp validate_schema(%{"type" => type} = schema, _depth)
       when type in ["string", "integer", "number", "boolean", "null"] do
    validate_scalar_constraints(type, schema)
  end

  defp validate_schema(%{"type" => "array", "items" => items} = schema, depth) do
    with :ok <- validate_non_negative(schema, "maxItems"),
         :ok <- validate_schema(items, depth + 1) do
      :ok
    end
  end

  defp validate_schema(_schema, _depth), do: {:error, :invalid_schema}

  defp validate_child_schemas(properties, depth) do
    Enum.reduce_while(properties, :ok, fn
      {key, child_schema}, :ok when is_binary(key) and byte_size(key) in 1..128 ->
        case validate_schema(child_schema, depth + 1) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _property, :ok ->
        {:halt, {:error, :invalid_schema}}
    end)
  end

  defp validate_scalar_constraints("string", schema),
    do: validate_non_negative(schema, "maxLength")

  defp validate_scalar_constraints(_type, _schema), do: :ok

  defp validate_non_negative(schema, key) do
    case Map.get(schema, key) do
      nil -> :ok
      value when is_integer(value) and value >= 0 -> :ok
      _value -> {:error, :invalid_schema}
    end
  end

  defp validate_value(_value, _schema, depth) when depth > @maximum_depth,
    do: {:error, :value_too_deep}

  defp validate_value(value, %{"type" => "object", "properties" => properties} = schema, depth)
       when is_map(value) do
    required = Map.get(schema, "required", [])
    additional? = Map.get(schema, "additionalProperties", false)
    keys = Map.keys(value)

    cond do
      not Enum.all?(required, &Map.has_key?(value, &1)) ->
        {:error, :required_property_missing}

      not additional? and not Enum.all?(keys, &Map.has_key?(properties, &1)) ->
        {:error, :additional_property_not_allowed}

      true ->
        Enum.reduce_while(value, :ok, fn {key, child_value}, :ok ->
          case Map.fetch(properties, key) do
            {:ok, child_schema} ->
              case validate_value(child_value, child_schema, depth + 1) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end

            :error when additional? ->
              {:cont, :ok}

            :error ->
              {:halt, {:error, :additional_property_not_allowed}}
          end
        end)
    end
  end

  defp validate_value(value, %{"type" => "array"} = schema, depth) when is_list(value) do
    maximum = Map.get(schema, "maxItems")

    if is_integer(maximum) and length(value) > maximum do
      {:error, :array_too_large}
    else
      Enum.reduce_while(value, :ok, fn child, :ok ->
        case validate_value(child, schema["items"], depth + 1) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_value(value, %{"type" => "string"} = schema, _depth) when is_binary(value) do
    maximum = Map.get(schema, "maxLength")

    if is_integer(maximum) and String.length(value) > maximum,
      do: {:error, :string_too_long},
      else: :ok
  end

  defp validate_value(value, %{"type" => "integer"}, _depth) when is_integer(value), do: :ok
  defp validate_value(value, %{"type" => "number"}, _depth) when is_number(value), do: :ok
  defp validate_value(value, %{"type" => "boolean"}, _depth) when is_boolean(value), do: :ok
  defp validate_value(nil, %{"type" => "null"}, _depth), do: :ok
  defp validate_value(_value, _schema, _depth), do: {:error, :type_mismatch}
end
