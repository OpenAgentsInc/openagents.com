defmodule OpenAgents.Forge.VisibilityTest do
  @moduledoc """
  TRANSPARENCY-001: the per-repo disclosure dial. A repo without a
  configured level is dark (:l0), the map is operator-owned config, and
  each capability has an explicit minimum level.
  """

  use OpenAgents.SarahDataCase, async: false
  alias OpenAgents.Forge.Visibility

  defp override_visibility(map) do
    previous = Application.get_env(:openagents, :forge_public_visibility)
    Application.put_env(:openagents, :forge_public_visibility, map)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:openagents, :forge_public_visibility, previous),
        else: Application.delete_env(:openagents, :forge_public_visibility)
    end)
  end

  test "levels are ordered lowest first" do
    assert Visibility.levels() == [:l0, :l1, :l2, :l3]
  end

  test "an unconfigured repo defaults to :l0 (dark)" do
    assert Visibility.level("demo") == :l0
    assert Visibility.level("does-not-exist") == :l0
  end

  test "the configured level is read from :forge_public_visibility" do
    # config.exs ships "sarah" at :l2 — it is a private repository.
    assert Visibility.level("sarah") == :l2

    override_visibility(%{"sarah" => :l1, "demo" => :l2})
    assert Visibility.level("sarah") == :l1
    assert Visibility.level("demo") == :l2
  end

  test "a non-binary repo is :l0 and admits nothing" do
    assert Visibility.level(nil) == :l0
    assert Visibility.level(123) == :l0
    assert Visibility.level(:openagents) == :l0

    refute Visibility.allows?(nil, :ledger)
    refute Visibility.allows?(123, :files)
    refute Visibility.allows?(:openagents, :diffs)
  end

  test ":ledger requires at least :l2" do
    override_visibility(%{"r0" => :l0, "r1" => :l1, "r2" => :l2, "r3" => :l3})

    refute Visibility.allows?("r0", :ledger)
    refute Visibility.allows?("r1", :ledger)
    assert Visibility.allows?("r2", :ledger)
    assert Visibility.allows?("r3", :ledger)
  end

  test ":files and :diffs require :l3" do
    override_visibility(%{"r0" => :l0, "r1" => :l1, "r2" => :l2, "r3" => :l3})

    for capability <- [:files, :diffs] do
      refute Visibility.allows?("r0", capability)
      refute Visibility.allows?("r1", capability)
      refute Visibility.allows?("r2", capability)
      assert Visibility.allows?("r3", capability)
    end
  end

  test "an unconfigured repo admits no capability at all" do
    refute Visibility.allows?("demo", :ledger)
    refute Visibility.allows?("demo", :files)
    refute Visibility.allows?("demo", :diffs)
  end

  describe "published documents (a private repo publishes files, not history)" do
    test "published?/2 reads the operator-owned allowlist" do
      override_paths(%{"sarah" => ["docs/a.md", "CHANGELOG.md"]})

      assert Visibility.published?("sarah", "docs/a.md")
      assert Visibility.published?("sarah", "CHANGELOG.md")
      refute Visibility.published?("sarah", "lib/secret.ex")
      refute Visibility.published?("other", "docs/a.md")
    end

    test "allows_file?/4 serves a published path only at head below :l3" do
      override_visibility(%{"sarah" => :l2})
      override_paths(%{"sarah" => ["docs/a.md"]})

      assert Visibility.allows_file?("sarah", "docs/a.md", "headsha", "headsha")
      # An older ref for the same published path is refused: publishing a
      # document must not publish its history.
      refute Visibility.allows_file?("sarah", "docs/a.md", "oldsha", "headsha")
      # A path that was never published is refused at any ref.
      refute Visibility.allows_file?("sarah", "lib/secret.ex", "headsha", "headsha")
    end

    test "allows_file?/4 serves anything at :l3, at any ref" do
      override_visibility(%{"sarah" => :l3})
      override_paths(%{"sarah" => []})

      assert Visibility.allows_file?("sarah", "lib/anything.ex", "oldsha", "headsha")
    end

    test "a dark repo publishes nothing even with an allowlist" do
      override_visibility(%{"sarah" => :l0})
      override_paths(%{"sarah" => ["docs/a.md"]})

      refute Visibility.allows?("sarah", :ledger)
      # allows_file?/4 still honors the explicit publication decision; the
      # surfaces gate on the level first, which is what makes :l0 dark.
      assert Visibility.published?("sarah", "docs/a.md")
    end
  end

  defp override_paths(map) do
    previous = Application.get_env(:openagents, :forge_public_paths)
    Application.put_env(:openagents, :forge_public_paths, map)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:openagents, :forge_public_paths, previous),
        else: Application.delete_env(:openagents, :forge_public_paths)
    end)
  end
end
