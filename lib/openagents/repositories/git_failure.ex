defmodule OpenAgents.Repositories.GitFailure do
  @moduledoc false

  @insufficient_storage_markers [
    "no space left on device",
    "disk quota exceeded"
  ]

  @temporary_storage_markers [
    "permission denied",
    "read-only file system"
  ]

  def classify(output, fallback) when is_binary(output) and is_atom(fallback) do
    normalized = String.downcase(output)

    cond do
      contains_any?(normalized, @insufficient_storage_markers) -> :insufficient_storage
      contains_any?(normalized, @temporary_storage_markers) -> :temporary_storage_unavailable
      true -> fallback
    end
  end

  def classify(_output, fallback) when is_atom(fallback), do: fallback

  defp contains_any?(output, markers), do: Enum.any?(markers, &String.contains?(output, &1))
end
