defmodule OpenAgents.Provenance.Canonical do
  @moduledoc "Deterministic JSON serialization and SHA-256 identity for provenance inputs."

  @type reason :: :unsupported_value | :duplicate_normalized_key

  @spec encode(term()) :: {:ok, String.t()} | {:error, reason()}
  def encode(value), do: canonical_json(value)

  @spec encode!(term()) :: String.t()
  def encode!(value) do
    case encode(value) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, "cannot canonically encode value: #{reason}"
    end
  end

  @spec digest(term()) :: {:ok, String.t()} | {:error, reason()}
  def digest(value) do
    with {:ok, encoded} <- encode(value) do
      {:ok, sha256(encoded)}
    end
  end

  @spec digest!(term()) :: String.t()
  def digest!(value) do
    case digest(value) do
      {:ok, digest} -> digest
      {:error, reason} -> raise ArgumentError, "cannot hash canonical value: #{reason}"
    end
  end

  @spec sha256(binary()) :: String.t()
  def sha256(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(value) when is_map(value) do
    with {:ok, entries} <- normalized_entries(value),
         false <- duplicate_keys?(entries),
         {:ok, encoded_entries} <- encode_entries(entries) do
      {:ok, "{" <> Enum.join(encoded_entries, ",") <> "}"}
    else
      true -> {:error, :duplicate_normalized_key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_json(value) when is_list(value) do
    with {:ok, encoded_values} <- encode_values(value) do
      {:ok, "[" <> Enum.join(encoded_values, ",") <> "]"}
    end
  end

  defp canonical_json(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: {:ok, Jason.encode!(value)}

  defp canonical_json(_value), do: {:error, :unsupported_value}

  defp normalized_entries(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn
      {key, nested_value}, {:ok, entries} when is_binary(key) or is_atom(key) ->
        {:cont, {:ok, [{to_string(key), nested_value} | entries]}}

      _entry, _entries ->
        {:halt, {:error, :unsupported_value}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, &elem(&1, 0))}
      error -> error
    end
  end

  defp duplicate_keys?(entries) do
    keys = Enum.map(entries, &elem(&1, 0))
    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp encode_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn {key, value}, {:ok, encoded_entries} ->
      case canonical_json(value) do
        {:ok, encoded_value} ->
          encoded_entry = Jason.encode!(key) <> ":" <> encoded_value
          {:cont, {:ok, [encoded_entry | encoded_entries]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> reverse_result()
  end

  defp encode_values(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, encoded_values} ->
      case canonical_json(value) do
        {:ok, encoded_value} -> {:cont, {:ok, [encoded_value | encoded_values]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_result()
  end

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result(error), do: error
end
