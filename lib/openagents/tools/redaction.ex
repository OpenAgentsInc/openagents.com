defmodule OpenAgents.Tools.Redaction do
  @moduledoc "Redacts credential-shaped fields before tool data reaches providers, clients, or storage."

  @redacted "[REDACTED]"
  @sensitive_fragments ~w(api_key authorization cookie credential password private_key secret token)
  @secret_patterns [
    ~r/\bsk-(?:or-v1-)?[A-Za-z0-9_-]{16,}\b/,
    ~r/\boa_(?:pat|agent|assignment)_[A-Za-z0-9._-]{16,}\b/,
    ~r/\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+\/-]+=*\b/i,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/
  ]

  @spec redact(term()) :: term()
  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_key?(key), do: {key, @redacted}, else: {key, redact(nested)}
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()

  def redact(value), do: value

  @spec redact_text(String.t()) :: String.t()
  def redact_text(value) when is_binary(value) do
    Enum.reduce(@secret_patterns, value, &Regex.replace(&1, &2, @redacted))
  end

  defp sensitive_key?(key) when is_atom(key), do: key |> Atom.to_string() |> sensitive_key?()

  defp sensitive_key?(key) when is_binary(key) do
    normalized = String.downcase(key)
    Enum.any?(@sensitive_fragments, &String.contains?(normalized, &1))
  end

  defp sensitive_key?(_key), do: false
end
