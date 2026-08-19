defmodule OpenAgents.Provenance.Canonical do
  @moduledoc false

  def encode(term) do
    Jason.encode(term)
  end

  def sha256(data) when is_binary(data) do
    Base.encode16(:crypto.hash(:sha256, data), case: :lower)
  end

  def digest(term) do
    {:ok, sha256(Jason.encode!(term))}
  end

  def digest!(term) do
    sha256(Jason.encode!(term))
  end
end
