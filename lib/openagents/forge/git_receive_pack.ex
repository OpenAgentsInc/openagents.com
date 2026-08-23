defmodule OpenAgents.Forge.GitReceivePack do
  @moduledoc false

  @spec refs(binary()) :: {:ok, [String.t()]} | {:error, :invalid_receive_pack}
  def refs(body) when is_binary(body), do: parse(body, [])

  defp parse(<<"0000", _rest::binary>>, refs), do: {:ok, Enum.reverse(refs)}

  defp parse(<<length::binary-size(4), rest::binary>>, refs) do
    with {size, ""} <- Integer.parse(length, 16),
         true <- size >= 4 and byte_size(rest) >= size - 4,
         payload = binary_part(rest, 0, size - 4),
         tail = binary_part(rest, size - 4, byte_size(rest) - size + 4) do
      case payload |> String.split(<<0>>, parts: 2) |> hd() |> String.trim() do
        "shallow " <> oid when oid != "" ->
          parse(tail, refs)

        line ->
          case String.split(line, " ", parts: 3) do
            [_old, _new, ref] when ref != "" -> parse(tail, [ref | refs])
            _ -> {:error, :invalid_receive_pack}
          end
      end
    else
      _ -> {:error, :invalid_receive_pack}
    end
  end

  defp parse(_body, _refs), do: {:error, :invalid_receive_pack}
end
