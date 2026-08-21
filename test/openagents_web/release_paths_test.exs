defmodule OpenAgentsWeb.ReleasePathsTest do
  @moduledoc """
  A path to a `priv` file must be resolved when it is used, not when the module
  is compiled.

  `Application.app_dir/2` and `:code.priv_dir/1` answer with the path of the
  application *as currently loaded*. Evaluated in a module attribute, that is
  the build machine's `_build` directory, and it is frozen into the compiled
  module. A release is built in one container and run in another, so the frozen
  path does not exist where the code actually runs.

  The failure is invisible in every environment that compiles and runs in the
  same place, which is every environment a test suite runs in. So this is a
  source-level check rather than a behavioural one: `/api/contracts/repositories-v1.json`
  answered 200 in development and 500 in production and staging both, and no
  test could have told the difference.
  """

  use OpenAgentsWeb.ConnCase, async: true

  # `@name Application.app_dir(...)` and `@name :code.priv_dir(...)`, including
  # the wrapped form the formatter produces for a long call.
  @baked ~r/^[ \t]*@[a-z_]+[ \t]+(?:Application\.app_dir|:code\.priv_dir)\b/m

  test "no module attribute resolves an application path at compile time" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          source = File.read!(path),
          [match] <- Regex.scan(@baked, source),
          do: {path, String.trim(match)}

    assert offenders == [], """
    These resolve an application directory into a module attribute, which
    freezes the build machine's path into the compiled module. The release runs
    somewhere else, so the file is not there and reading it raises:

    #{Enum.map_join(offenders, "\n", fn {file, line} -> "  #{file}\n    #{line}" end)}

    Move the call into a function so it is resolved when it is used.
    """
  end

  describe "the contract endpoint" do
    test "serves the contract with an etag", %{conn: conn} do
      conn = get(conn, ~p"/api/contracts/repositories-v1.json")

      assert response = response(conn, 200)
      assert {:ok, decoded} = Jason.decode(response)
      assert is_map(decoded)

      assert ["public, max-age=300"] = get_resp_header(conn, "cache-control")
      assert [etag] = get_resp_header(conn, "etag")
      assert etag =~ ~r/^"[0-9a-f]{64}"$/
    end
  end
end
