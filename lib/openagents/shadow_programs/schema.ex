defmodule OpenAgents.ShadowPrograms.Schema do
  @moduledoc "Bounded JSON-schema subset used at both sides of shadow inference."

  @maximum_bytes 16_384

  def validate(value, schema) when is_map(schema) do
    if byte_size(Jason.encode!(value)) > @maximum_bytes,
      do: {:error, :typed_value_too_large},
      else: validate_value(value, schema)
  end

  def validate(_value, _schema), do: {:error, :typed_schema_invalid}

  defp validate_value(value, %{"type" => "object"} = schema) when is_map(value) do
    properties = schema["properties"] || %{}
    required = schema["required"] || []
    keys = Map.keys(value)

    cond do
      Enum.any?(required, &(not Map.has_key?(value, &1))) ->
        {:error, :required_field_missing}

      schema["additionalProperties"] == false and
          Enum.any?(keys, &(not Map.has_key?(properties, &1))) ->
        {:error, :unexpected_field}

      true ->
        validate_properties(value, properties)
    end
  end

  defp validate_value(value, %{"type" => "string"} = schema) when is_binary(value) do
    if byte_size(value) <= Map.get(schema, "maxLength", 8_000),
      do: :ok,
      else: {:error, :string_too_large}
  end

  defp validate_value(value, %{"type" => "number"} = schema) when is_number(value) do
    if value >= Map.get(schema, "minimum", value) and value <= Map.get(schema, "maximum", value),
      do: :ok,
      else: {:error, :number_out_of_range}
  end

  defp validate_value(value, %{"type" => "boolean"}) when is_boolean(value), do: :ok

  defp validate_value(nil, %{"type" => types}) when is_list(types) do
    if "null" in types, do: :ok, else: {:error, :type_mismatch}
  end

  defp validate_value(value, %{"type" => types} = schema) when is_list(types) do
    Enum.reduce_while(types, {:error, :type_mismatch}, fn type, _error ->
      case validate_value(value, Map.put(schema, "type", type)) do
        :ok -> {:halt, :ok}
        {:error, _reason} -> {:cont, {:error, :type_mismatch}}
      end
    end)
  end

  defp validate_value(value, %{"type" => "array"} = schema) when is_list(value) do
    maximum = Map.get(schema, "maxItems", 64)

    if length(value) <= maximum,
      do: validate_items(value, schema["items"] || %{}),
      else: {:error, :array_too_large}
  end

  defp validate_value(value, %{"enum" => allowed}),
    do: if(value in allowed, do: :ok, else: {:error, :enum_mismatch})

  defp validate_value(_value, _schema), do: {:error, :type_mismatch}

  defp validate_properties(value, properties) do
    Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
      case validate_value(nested, properties[key]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {key, reason}}}
      end
    end)
  end

  defp validate_items(items, schema) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case validate_value(item, schema) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
