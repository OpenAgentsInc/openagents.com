defmodule OpenAgentsWeb.RouteAuthorityTest do
  use ExUnit.Case, async: true

  alias OpenAgentsWeb.RouteAuthority

  test "every HTTP route and endpoint socket declares one authority, principal, and scope" do
    inventory = RouteAuthority.inventory()

    assert [_ | _] = inventory

    Enum.each(inventory, fn entry ->
      assert entry.class in RouteAuthority.classes(), inspect(entry)
      assert is_binary(entry.principal) and entry.principal != "", inspect(entry)
      assert is_binary(entry.scope) and entry.scope != "", inspect(entry)

      if entry.verb in ["post", "put", "patch", "delete", "connect", "*"] do
        assert entry.mutation, inspect(entry)
      end

      if entry.mutation do
        refute entry.class == :public_read, inspect(entry)
      end
    end)
  end

  test "public forge reads and bearer-authenticated forge writes are separate" do
    read = route!(:get, "/api/v3/repos/:owner/:repo/issues")
    write = route!(:post, "/api/v3/repos/:owner/:repo/issues")

    assert read.class == :public_read
    assert read.mutation == false
    assert write.class == :authenticated_api
    assert write.principal == "first-party bearer token"
    assert write.scope == "forge:write"
    assert write.mutation

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "GET",
             "/api/v3/repos/OpenAgentsInc/openagents.com/issues",
             "stage.openagents.com"
           ).pipe_through == [:api]

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "POST",
             "/api/v3/repos/OpenAgentsInc/openagents.com/issues",
             "stage.openagents.com"
           ).pipe_through == [:forge_write_api]
  end

  test "operator and machine surfaces cannot drift into browser or public classes" do
    assert route!(:get, "/admin").class == :operator
    assert route!(:get, "/admin/forge").scope == "forge:promote"
    assert route!(:get, "/admin/scv/accounts").scope == "scv:account:connect"
    assert route!(:post, "/controller/pairings").class == :machine
    assert route!(:get, "/controller/pairings/:id").scope == "machine:pairing:claim"
    assert route!(:post, "/api/inference/proxy").class == :internal_service
  end

  test "the OAuth callback suppresses router parameter logging at the application boundary" do
    callback =
      Enum.find(OpenAgentsWeb.Router.__routes__(), &(&1.path == "/auth/github/callback"))

    assert callback.metadata.log == false

    assert Phoenix.Logger.filter_values(%{
             "code" => "oauth-code-sentinel",
             "state" => "oauth-state-sentinel",
             "safe" => "visible"
           }) == %{
             "code" => "[FILTERED]",
             "state" => "[FILTERED]",
             "safe" => "visible"
           }
  end

  defp route!(verb, path) do
    Enum.find(RouteAuthority.inventory(), &(&1.verb == to_string(verb) and &1.path == path)) ||
      flunk("missing route #{verb} #{path}")
  end
end
