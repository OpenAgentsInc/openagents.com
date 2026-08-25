defmodule OpenAgentsWeb.Plugs.ApiV3RewriteTest do
  use OpenAgentsWeb.ConnCase, async: true

  alias OpenAgentsWeb.Plugs.ApiV3Rewrite

  describe "unit test call/2" do
    test "rewrites api/v3 prefix to api/v1" do
      conn = %Plug.Conn{path_info: ["api", "v3", "repos", "owner", "repo", "issues"]}
      rewritten = ApiV3Rewrite.call(conn, [])

      assert rewritten.path_info == ["api", "v1", "repos", "owner", "repo", "issues"]
    end

    test "rewrites root api/v3 path" do
      conn = %Plug.Conn{path_info: ["api", "v3"]}
      rewritten = ApiV3Rewrite.call(conn, [])

      assert rewritten.path_info == ["api", "v1"]
    end

    test "leaves api/v1 and other paths untouched" do
      conn_v1 = %Plug.Conn{path_info: ["api", "v1", "repos"]}
      assert ApiV3Rewrite.call(conn_v1, []) == conn_v1

      conn_status = %Plug.Conn{path_info: ["status"]}
      assert ApiV3Rewrite.call(conn_status, []) == conn_status
    end
  end

  describe "integration through Endpoint" do
    test "GET /api/v3 transparently answers from the /api/v1 root document", %{conn: conn} do
      res = get(conn, "/api/v3")

      assert json_response(res, 200)["api_version"] == "v1"
    end

    test "GET /api/v3/repos/:owner/:repo/issues transparently answers from /api/v1", %{conn: conn} do
      res = get(conn, "/api/v3/repos/OpenAgentsInc/openagents.com/issues")

      assert json_response(res, 200)["issues"] != nil
    end
  end
end
