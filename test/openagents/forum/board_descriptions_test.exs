defmodule OpenAgents.Forum.BoardDescriptionsTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Forum.BoardDescriptions

  # The ten boards the legacy forum carries. A board that arrives without a
  # written description falls back to nothing, which is how the forum home
  # page ended up able to render an internal content pointer at readers.
  @imported_slugs ~w(
    artanis mining product-promises psionic release-candidates
    site-builder-help tassadar video-series-discussion void work-requests
  )

  test "every imported board has a description" do
    assert BoardDescriptions.slugs() == Enum.sort(@imported_slugs)

    for slug <- @imported_slugs do
      assert is_binary(BoardDescriptions.fetch(slug)), "#{slug} has no description"
    end
  end

  test "descriptions read as one or two plain sentences" do
    for slug <- @imported_slugs do
      description = BoardDescriptions.fetch(slug)

      assert String.ends_with?(description, "."), "#{slug} does not end in a period"
      assert String.length(description) <= 200, "#{slug} is too long for a board subtitle"
      refute description =~ ~r/\bsimply\b|\bjust\b|!/, "#{slug} breaks the style guide"
    end
  end

  test "an unknown board has no description" do
    refute BoardDescriptions.fetch("nonexistent")
    refute BoardDescriptions.fetch(nil)
  end
end
