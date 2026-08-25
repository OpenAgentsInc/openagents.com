defmodule OpenAgentsWeb.ApiVersionPostureTest do
  @moduledoc """
  Proves FORGEAPI-002: the version in the path is this API's own, and the
  `/api/v3` alias is gone.

  The alias was removed on 2026-08-25 (#216), once the only client that used
  it was upgraded. These assertions keep the old prefix from coming back by
  the same quiet route it would have left by: a link or a rendered `url`
  written against it looks fine until someone follows it.
  """

  use ExUnit.Case, async: true

  @legacy_prefix "api/v3"

  test "every versioned route is declared at /api/v1" do
    misversioned =
      OpenAgentsWeb.Router.__routes__()
      |> Enum.map(& &1.path)
      |> Enum.filter(&Regex.match?(~r{^/api/v\d}, &1))
      |> Enum.reject(&String.starts_with?(&1, "/api/v1"))

    assert misversioned == [], """
    These routes declare a version segment other than v1:

    #{Enum.map_join(misversioned, "\n", &"  #{&1}")}

    The path names this API's version, and no other version is served.
    """
  end

  test "no file under lib/ names the old prefix" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(&String.contains?(File.read!(&1), @legacy_prefix))

    assert offenders == [], """
    These files name `/#{@legacy_prefix}`:

    #{Enum.map_join(offenders, "\n", &"  #{&1}")}

    A route, a rendered `url` field, or a receipt hint that names the alias
    breaks when the alias is deleted. Name `/api/v1`, which is what the router
    serves and what the alias rewrites to.
    """
  end
end
