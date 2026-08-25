defmodule OpenAgentsWeb.ApiVersionPostureTest do
  @moduledoc """
  Proves FORGEAPI-002: the version in the path is this API's own, and `/api/v3`
  is a dated alias nothing is allowed to depend on.

  The alias is one plug and one deletion away from gone. These assertions keep
  it that way, because the failure mode is quiet: a route or a rendered link
  written against the old prefix works perfectly until the day the alias is
  removed, and then it does not.
  """

  use ExUnit.Case, async: true

  @alias_plug "lib/openagents_web/plugs/api_v3_rewrite.ex"
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

    The path names this API's version. Old prefixes are served by
    OpenAgentsWeb.Plugs.ApiV3Rewrite, never declared in the router.
    """
  end

  test "the alias plug is the only file under lib/ that names the old prefix" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&(&1 == @alias_plug))
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
