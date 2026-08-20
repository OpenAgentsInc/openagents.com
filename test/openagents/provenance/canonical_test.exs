defmodule OpenAgents.Provenance.CanonicalTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Provenance.Canonical

  test "map key order and atom/string representation are canonical" do
    first = %{role: "user", content: "hello", nested: %{"b" => 2, "a" => 1}}
    second = %{"nested" => %{"a" => 1, "b" => 2}, "content" => "hello", "role" => "user"}

    assert Canonical.encode!(first) == Canonical.encode!(second)
    assert Canonical.digest!(first) == Canonical.digest!(second)
    assert byte_size(Canonical.digest!(first)) == 64
  end

  test "list order remains material" do
    refute Canonical.digest!(["first", "second"]) == Canonical.digest!(["second", "first"])
  end

  test "rejects unsupported values and duplicate normalized keys" do
    assert {:error, :unsupported_value} = Canonical.encode({:tuple, "unsupported"})
    assert {:error, :duplicate_normalized_key} = Canonical.encode(%{:key => 1, "key" => 2})
  end
end
