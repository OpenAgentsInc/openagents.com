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

  test "GitHub sign-in is the bounded public identity action" do
    route = route!(:post, "/auth/github")

    assert route.class == :public_action
    assert route.principal == "OAuth applicant"
    assert route.scope == "identity:sign-in"
    assert route.mutation
  end

  test "public forge reads and bearer-authenticated forge writes are separate" do
    read = route!(:get, "/api/v1/repos/:owner/:repo/issues")
    write = route!(:post, "/api/v1/repos/:owner/:repo/issues")

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
             "/api/v1/repos/OpenAgentsInc/openagents.com/issues",
             "stage.openagents.com"
           ).pipe_through == [:optional_forge_api]

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "POST",
             "/api/v1/repos/OpenAgentsInc/openagents.com/issues",
             "stage.openagents.com"
           ).pipe_through == [:agent_participation_api]
  end

  # The six ancillary issue families used to sit behind the credential-free
  # `:api` pipeline, which discarded a bearer token, so a private repository
  # refused its own owner. They are declared here rather than falling through
  # the `/api/v1` read catch-all, whose "anonymous" principal is now wrong for
  # them.
  test "issue metadata reads accept an optional bearer instead of discarding it" do
    for path <- [
          "/api/v1/repos/:owner/:repo/issues/:issue_number/comments",
          "/api/v1/repos/:owner/:repo/issues/comments/:id",
          "/api/v1/repos/:owner/:repo/issues/:issue_number/labels",
          "/api/v1/repos/:owner/:repo/issues/:issue_number/assignees",
          "/api/v1/repos/:owner/:repo/labels",
          "/api/v1/repos/:owner/:repo/labels/:name",
          "/api/v1/repos/:owner/:repo/milestones",
          "/api/v1/repos/:owner/:repo/milestones/:milestone_number",
          "/api/v1/repos/:owner/:repo/assignees",
          "/api/v1/repos/:owner/:repo/assignees/:assignee"
        ] do
      route = route!(:get, path)

      assert route.class == :public_read, inspect(route)
      assert route.principal == "anonymous or first-party bearer token", inspect(route)
      assert route.scope == "forge:repository:read", inspect(route)
      refute route.mutation, inspect(route)
    end

    for path <- [
          "/api/v1/repos/OpenAgentsInc/openagents.com/issues/1/comments",
          "/api/v1/repos/OpenAgentsInc/openagents.com/issues/comments/1",
          "/api/v1/repos/OpenAgentsInc/openagents.com/issues/1/labels",
          "/api/v1/repos/OpenAgentsInc/openagents.com/issues/1/assignees",
          "/api/v1/repos/OpenAgentsInc/openagents.com/labels",
          "/api/v1/repos/OpenAgentsInc/openagents.com/labels/bug",
          "/api/v1/repos/OpenAgentsInc/openagents.com/milestones",
          "/api/v1/repos/OpenAgentsInc/openagents.com/milestones/1",
          "/api/v1/repos/OpenAgentsInc/openagents.com/assignees",
          "/api/v1/repos/OpenAgentsInc/openagents.com/assignees/someone"
        ] do
      assert Phoenix.Router.route_info(
               OpenAgentsWeb.Router,
               "GET",
               path,
               "stage.openagents.com"
             ).pipe_through == [:optional_forge_api],
             "#{path} no longer runs behind the optional bearer"
    end
  end

  test "agent credential rotation is an agent-scoped bearer write" do
    route = route!(:post, "/api/v1/agent/credentials")

    assert route.class == :authenticated_api
    assert route.principal == "agent bearer token"
    assert route.scope == "agent:participate"
    assert route.mutation

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "POST",
             "/api/v1/agent/credentials",
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
    forge_user = route!(:get, "/api/v1/user")
    repository_list = route!(:get, "/api/v1/user/repos")
    import_status = route!(:get, "/api/v1/repository-imports/:id")
    repository_view = route!(:get, "/api/v1/repos/:owner/:repo")

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
             "/api/v1/user",
             "stage.openagents.com"
           ).pipe_through == [:forge_write_api]

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "GET",
             "/api/v1/user/repos",
             "stage.openagents.com"
           ).pipe_through == [:forge_write_api]

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "GET",
             "/api/v1/repos/octavia/project",
             "stage.openagents.com"
           ).pipe_through == [:optional_forge_api]
  end

  test "account chat uses its own scoped bearer pipeline" do
    events = route!(:get, "/api/v1/chat/events")
    turns = route!(:post, "/api/v1/chat/turns")
    coder_identity = route!(:get, "/api/v1/coder/identity")

    assert events.scope == "chat:account"
    refute events.mutation
    assert turns.scope == "chat:account"
    assert turns.mutation
    assert coder_identity.scope == "chat:account"
    refute coder_identity.mutation

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "GET",
             "/api/v1/chat/events",
             "stage.openagents.com"
           ).pipe_through == [:chat_account_api]

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "POST",
             "/api/v1/chat/turns",
             "stage.openagents.com"
           ).pipe_through == [:chat_account_api]

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "GET",
             "/api/v1/coder/identity",
             "stage.openagents.com"
           ).pipe_through == [:chat_account_api]
  end

  test "Box control uses its human or delegated bearer pipeline" do
    route = route!(:get, "/api/v1/conversations/:conversation_id/boxes")
    create = route!(:post, "/api/v1/conversations/:conversation_id/boxes")
    command = route!(:post, "/api/v1/conversations/:conversation_id/boxes/:box_id/commands")

    assert route.class == :authenticated_api
    assert route.principal == "human or delegated box-control bearer token"
    assert route.scope == "box:control"
    refute route.mutation
    assert create.mutation
    assert command.mutation

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "GET",
             "/api/v1/conversations/00000000-0000-4000-8000-000000000001/boxes",
             "stage.openagents.com"
           ).pipe_through == [:box_control_api]
  end

  test "operator and computer surfaces cannot drift into browser or public classes" do
    assert route!(:get, "/admin").class == :operator
    assert route!(:get, "/admin/forge").scope == "forge:promote"
    assert route!(:get, "/admin/scv/accounts").scope == "scv:account:connect"
    assert route!(:post, "/controller/pairings").class == :computer
    assert route!(:get, "/controller/pairings/:id").scope == "computer:pairing:claim"
    assert route!(:get, "/controller/status").scope == "computer:status"
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

  test "fleet promotion is an operator mutation, not a generic api v1 write" do
    create = route!(:post, "/api/v1/admin/forge/targets")
    show = route!(:get, "/api/v1/admin/forge/targets/:id")
    index = route!(:get, "/api/v1/admin/forge/targets")

    for route <- [create, show, index] do
      assert route.class == :operator, inspect(route)
      assert route.principal == "current operator holding a privileged bearer token"
      assert route.scope == "deployments:promote"
    end

    assert create.mutation
    refute show.mutation
    refute index.mutation

    # The tenant deployment plane is a different scope on a different path, and
    # neither the generic /api/v1 write catch-all nor `deployments:write`
    # reaches fleet promotion.
    tenant = route!(:post, "/api/v1/repos/:owner/:repo/deployments")
    assert tenant.scope == "deployments:write"
    assert tenant.class == :authenticated_api

    for path <- ["/api/v1/admin/forge/targets", "/api/v1/admin/forge/targets/:id"] do
      assert Phoenix.Router.route_info(
               OpenAgentsWeb.Router,
               "GET",
               String.replace(path, ":id", "00000000-0000-4000-8000-000000000001"),
               "stage.openagents.com"
             ).pipe_through == [:fleet_promotion_api]
    end

    assert Phoenix.Router.route_info(
             OpenAgentsWeb.Router,
             "POST",
             "/api/v1/admin/forge/targets",
             "stage.openagents.com"
           ).pipe_through == [:fleet_promotion_api]
  end

  test "plugin discovery routes are public and not substring matched" do
    for path <- ["/api/v1/plugins", "/api/v1/plugins/:name"] do
      route = route!(:get, path)

      assert route.class == :public_read, inspect(route)
      assert route.principal == "anonymous", inspect(route)
      assert route.scope == "plugins:discover", inspect(route)
      refute route.mutation, inspect(route)
    end

    refute Enum.any?(
             OpenAgentsWeb.Router.__routes__(),
             &(&1.path == "/api/v1/pluginsXYZ")
           )
  end

  defp route!(verb, path) do
    Enum.find(RouteAuthority.inventory(), &(&1.verb == to_string(verb) and &1.path == path)) ||
      flunk("missing route #{verb} #{path}")
  end
end
