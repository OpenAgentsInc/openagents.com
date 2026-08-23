defmodule OpenAgents.Stacks.OID do
  @moduledoc """
  Git object ID stored as raw bytes.

  Casts lowercase hex strings for SHA-1 (40 characters) and SHA-256
  (64 characters) object names, stores the decoded 20-byte or 32-byte
  binary, and loads back to the hex string.
  """
  use Ecto.Type

  @impl true
  def type, do: :binary

  @impl true
  def cast(hex) when is_binary(hex) and byte_size(hex) in [40, 64] do
    case Base.decode16(hex, case: :lower) do
      {:ok, raw} -> {:ok, hex_from_raw(raw)}
      :error -> :error
    end
  end

  def cast(_other), do: :error

  @impl true
  def dump(hex) when is_binary(hex) and byte_size(hex) in [40, 64] do
    Base.decode16(hex, case: :lower)
  end

  def dump(_other), do: :error

  @impl true
  def load(raw) when is_binary(raw) and byte_size(raw) in [20, 32] do
    {:ok, hex_from_raw(raw)}
  end

  def load(_other), do: :error

  defp hex_from_raw(raw), do: Base.encode16(raw, case: :lower)
end
