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
    assert read.principal == "anonymous or first-party bearer token"
    assert read.scope == "forge:repository:read"
    assert read.mutation == false
    assert write.class == :authenticated_api
    assert write.principal == "first-party human or agent bearer token"
    assert write.scope == "forge:write or agent:participate"
    assert write.mutation

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "GET",
             "/api/v3/repos/OpenAgentsInc/openagents.com/issues",
             "stage.openagents.com"
           ).pipe_through == [:optional_forge_api]

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "POST",
             "/api/v3/repos/OpenAgentsInc/openagents.com/issues",
             "stage.openagents.com"
           ).pipe_through == [:agent_participation_api]
  end

  test "agent credential rotation is an agent-scoped bearer write" do
    route = route!(:post, "/api/v3/agent/credentials")

    assert route.class == :authenticated_api
    assert route.principal == "agent bearer token"
    assert route.scope == "agent:participate"
    assert route.mutation

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "POST",
             "/api/v3/agent/credentials",
             "stage.openagents.com"
           ).pipe_through == [:agent_token_api]
  end

  test "public browser forge surfaces remain separate from authenticated entries" do
    for {path, scope} <- [
          {"/issues", "forge:issues:web"},
          {"/projects", "forge:projects:web"}
        ] do
      route = route!(:get, path)

      assert route.class == :public_read
      assert route.principal == "anonymous visitor or signed-in person"
      assert route.scope == scope
      refute route.mutation
    end

    for path <- [
          "/:owner/:repo/labels",
          "/:owner/:repo/milestones",
          "/:owner/:repo/projects",
          "/:owner/:repo/projects/:number"
        ] do
      route = route!(:get, path)

      assert route.class == :public_read
      assert route.principal == "anonymous visitor or signed-in person"
      assert route.scope == "forge:repository:web"
      refute route.mutation
    end

    assert route!(:get, "/:owner/:repo/issues/new").class == :authenticated_browser
    assert route!(:get, "/:owner/:repo/members").class == :authenticated_browser
    assert route!(:get, "/:owner/:repo/assignees").class == :authenticated_browser
  end

  test "repository identity, list, and import status reads require bearer authentication" do
    forge_user = route!(:get, "/api/v3/user")
    repository_list = route!(:get, "/api/v3/user/repos")
    import_status = route!(:get, "/api/v3/repository-imports/:id")
    repository_view = route!(:get, "/api/v3/repos/:owner/:repo")

    assert forge_user.class == :authenticated_api
    assert forge_user.scope == "forge:read"
    assert repository_list.class == :authenticated_api
    assert repository_list.scope == "forge:read"
    assert import_status.class == :authenticated_api
    assert import_status.scope == "forge:read"
    assert repository_view.class == :public_read
    assert repository_view.principal == "anonymous or first-party bearer token"

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "GET",
             "/api/v3/user",
             "stage.openagents.com"
           ).pipe_through == [:forge_write_api]

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "GET",
             "/api/v3/user/repos",
             "stage.openagents.com"
           ).pipe_through == [:forge_write_api]

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "GET",
             "/api/v3/repos/octavia/project",
             "stage.openagents.com"
           ).pipe_through == [:optional_forge_api]
  end

  test "account chat uses its own scoped bearer pipeline" do
    events = route!(:get, "/api/v3/chat/events")
    turns = route!(:post, "/api/v3/chat/turns")

    assert events.scope == "chat:account"
    refute events.mutation
    assert turns.scope == "chat:account"
    assert turns.mutation

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "GET",
             "/api/v3/chat/events",
             "stage.openagents.com"
           ).pipe_through == [:chat_account_api]

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "POST",
             "/api/v3/chat/turns",
             "stage.openagents.com"
           ).pipe_through == [:chat_account_api]
  end

  test "Box control uses its human or delegated bearer pipeline" do
    route = route!(:get, "/api/v3/conversations/:conversation_id/boxes")
    create = route!(:post, "/api/v3/conversations/:conversation_id/boxes")
    command = route!(:post, "/api/v3/conversations/:conversation_id/boxes/:box_id/commands")

    assert route.class == :authenticated_api
    assert route.principal == "human or delegated box-control bearer token"
    assert route.scope == "box:control"
    refute route.mutation
    assert create.mutation
    assert command.mutation

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "GET",
             "/api/v3/conversations/00000000-0000-4000-8000-000000000001/boxes",
             "stage.openagents.com"
           ).pipe_through == [:box_control_api]
  end

  test "operator and computer surfaces cannot drift into browser or public classes" do
    assert route!(:get, "/admin").class == :operator
    assert route!(:get, "/admin/forge").scope == "forge:promote"
    assert route!(:get, "/admin/scv/accounts").scope == "scv:account:connect"
    assert route!(:post, "/controller/pairings").class == :computer
    assert route!(:get, "/controller/pairings/:id").scope == "computer:pairing:claim"
    assert route!(:post, "/api/inference/proxy").class == :internal_service
    assert Enum.find(RouteAuthority.socket_inventory(), &(&1.path == "/controller/socket"))

    assert Enum.any?(OpenAgentsWeb.Endpoint.__sockets__(), fn
             {"/controller/socket", OpenAgentsWeb.ControllerSocket, _options} -> true
             _socket -> false
           end)
  end

  test "the canonical Forge smart HTTP routes run through credential authentication" do
    route =
      Phoenix.Router.route_info(
        OpenAgentsWeb.Router,
        "GET",
        "/OpenAgentsInc/openagents.com.git/info/refs",
        "stage.openagents.com"
      )

    assert route.pipe_through == [:forge_git]
    assert route.route == "/:owner/:repo/info/refs"
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
