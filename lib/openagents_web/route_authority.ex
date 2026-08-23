defmodule OpenAgentsWeb.RouteAuthority do
  @moduledoc """
  Executable authority inventory for every Phoenix route and endpoint socket.

  The classifier intentionally has no catch-all policy. A route outside one of
  these bounded surfaces is `:unclassified`, which fails the inventory test
  until its principal and scope are chosen deliberately.
  """

  @classes [
    :public_read,
    :authenticated_browser,
    :authenticated_api,
    :operator,
    :machine,
    :internal_service,
    :git_transport
  ]

  @public_browser_paths [
    "/",
    "/status",
    "/changelog",
    "/leaderboard",
    "/components",
    "/components/icons",
    "/components/:slug",
    "/docs",
    "/docs/:slug",
    "/health",
    "/healthz"
  ]

  @authenticated_browser_prefixes [
    "/sarah",
    "/computers",
    "/voice/",
    "/data",
    "/artifact-catalog",
    "/machines",
    # No trailing slash: the memory page is "/memory" itself, and its export
    # lives under it.
    "/memory",
    "/device",
    "/repositories",
    # The forum. Reading and posting happen signed in, matching the other
    # workspace-wide surfaces.
    "/forum",
    "/settings/api-tokens",
    "/github/connection",
    "/api/tokens",
    "/api/computers",
    "/api/capacity",
    "/api/computer-agent-jobs/"
  ]

  @optional_forge_read_paths [
    "/api/v3/repos/:owner/:repo/issues",
    "/api/v3/repos/:owner/:repo/issues/:issue_number",
    "/api/v3/repos/:owner/:repo/issues/:issue_number/dependencies",
    "/api/v3/repos/:owner/:repo/pulls",
    "/api/v3/repos/:owner/:repo/pulls/:pull_number",
    "/api/v3/repos/:owner/:repo/projectsV2",
    "/api/v3/repos/:owner/:repo/projectsV2/:project_number",
    "/api/v3/repos/:owner/:repo/projectsV2/:project_number/items",
    "/api/v3/repos/:owner/:repo/projectsV2/:project_number/items/:item_id/events",
    "/api/v3/repos/:owner/:repo/projectsV2/:project_number/fields"
  ]

  @spec classes() :: [atom()]
  def classes, do: @classes

  @spec inventory() :: [map()]
  def inventory do
    routes = Enum.map(OpenAgentsWeb.Router.__routes__(), &classify/1)
    routes ++ socket_inventory()
  end

  @spec classify(map()) :: map()
  def classify(route) do
    base = %{
      transport: :http,
      verb: to_string(route.verb),
      path: route.path,
      handler: inspect(route.plug),
      action: inspect(route.plug_opts)
    }

    Map.merge(base, policy(route))
  end

  @spec socket_inventory() :: [map()]
  def socket_inventory do
    [
      %{
        transport: :websocket,
        verb: "connect",
        path: "/live",
        handler: "Phoenix.LiveView.Socket",
        action: "connect",
        class: :authenticated_browser,
        principal: "encrypted browser session",
        scope: "liveview:session",
        mutation: true
      },
      %{
        transport: :websocket,
        verb: "connect",
        path: "/controller/socket",
        handler: "OpenAgentsWeb.ControllerSocket",
        action: "connect",
        class: :machine,
        principal: "active paired-machine bearer",
        scope: "machine:channel",
        mutation: true
      }
    ]
  end

  defp policy(%{path: path, verb: verb})
       when path in @public_browser_paths and verb in [:get, :head],
       do: declaration(:public_read, "anonymous", "published:web", false)

  defp policy(%{path: "/issues", verb: verb}) when verb in [:get, :head],
    do:
      declaration(
        :public_read,
        "anonymous visitor or signed-in person",
        "forge:issues:web",
        false
      )

  defp policy(%{path: "/projects", verb: verb}) when verb in [:get, :head],
    do:
      declaration(
        :public_read,
        "anonymous visitor or signed-in person",
        "forge:projects:web",
        false
      )

  defp policy(%{path: "/auth/github", verb: :post}),
    do: declaration(:authenticated_browser, "explicit OAuth applicant", "identity:connect", true)

  defp policy(%{path: "/auth/github/callback"}),
    do: declaration(:authenticated_browser, "one-time OAuth attempt", "identity:connect", true)

  defp policy(%{path: "/logout"}),
    do: declaration(:authenticated_browser, "encrypted browser session", "session:delete", true)

  defp policy(%{path: "/chat"}),
    do: declaration(:operator, "configured operator GitHub ID", "chat:preview", false)

  defp policy(%{path: "/admin/analytics"}),
    do: declaration(:operator, "configured operator GitHub ID", "analytics:read", false)

  defp policy(%{path: "/admin/tokens"}),
    do: declaration(:operator, "configured operator GitHub ID", "tokens:productivity:read", false)

  defp policy(%{path: "/admin/forge"}),
    do: declaration(:operator, "configured operator GitHub ID", "forge:promote", true)

  defp policy(%{path: "/admin/scv/accounts"}),
    do: declaration(:operator, "configured operator GitHub ID", "scv:account:connect", true)

  defp policy(%{path: "/admin/forum/claims"}),
    do: declaration(:operator, "configured operator GitHub ID", "forum:identity:link", true)

  defp policy(%{path: "/admin/recordings"}),
    do: declaration(:operator, "configured operator GitHub ID", "voice:recording:list", false)

  defp policy(%{path: "/admin/recordings/:id/audio"}),
    do: declaration(:operator, "configured operator GitHub ID", "voice:recording:read", false)

  defp policy(%{path: "/admin"}),
    do: declaration(:operator, "configured operator GitHub ID", "voice:metadata:read", false)

  defp policy(%{path: path})
       when path in [
              "/:owner/:repo/info/refs",
              "/:owner/:repo/git-upload-pack",
              "/:owner/:repo/git-receive-pack",
              "/git"
            ],
       do:
         declaration(
           :git_transport,
           "anonymous read or authorized user, operator, or paired-machine HTTP credential",
           "git:repository",
           true
         )

  defp policy(%{path: "/api/status", verb: verb}) when verb in [:get, :head],
    do: declaration(:public_read, "anonymous", "published:status", false)

  defp policy(%{path: "/api/capacity", verb: verb}) when verb in [:get, :head],
    do:
      declaration(:authenticated_api, "active encrypted browser session", "capacity:self", false)

  defp policy(%{path: "/api/changelog", verb: verb}) when verb in [:get, :head],
    do: declaration(:public_read, "anonymous", "published:changelog", false)

  defp policy(%{path: path, verb: verb})
       when path in [
              "/api/contracts/repositories-v1.json",
              "/api/contracts/do-not-build-v1.json"
            ] and
              verb in [:get, :head],
       do: declaration(:public_read, "anonymous", "published:api-contract", false)

  defp policy(%{path: "/api/v3", verb: verb}) when verb in [:get, :head],
    do: declaration(:public_read, "anonymous", "published:api-extensions", false)

  defp policy(%{path: "/controller/pairings", verb: :post}),
    do: declaration(:machine, "unpaired machine", "machine:pairing:create", true)

  defp policy(%{path: "/controller/pairings/:id"}),
    do: declaration(:machine, "expiring one-time poll secret", "machine:pairing:claim", true)

  defp policy(%{path: "/api/inference/proxy"}),
    do: declaration(:internal_service, "scoped inference grant", "inference:invoke", true)

  defp policy(%{path: "/api/artifact-listings" <> _path, verb: verb})
       when verb in [:get, :head],
       do:
         declaration(
           :authenticated_api,
           "active encrypted browser session",
           "artifact-catalog:read",
           false
         )

  defp policy(%{path: "/api/v3/agent/credentials", verb: :post}),
    do:
      declaration(
        :authenticated_api,
        "agent bearer token",
        "agent:participate",
        true
      )

  defp policy(%{path: "/api/operator/artifact-listings" <> _path, verb: verb}),
    do:
      declaration(
        :operator,
        "configured operator GitHub ID",
        "artifact-catalog:operate",
        verb not in [:get, :head]
      )

  defp policy(%{path: "/api/operator/continual-learning" <> _path, verb: verb}),
    do:
      declaration(
        :operator,
        "configured operator GitHub ID",
        "continual-learning:operate",
        verb not in [:get, :head]
      )

  defp policy(%{path: "/api/operator/agents/" <> _path, verb: verb}),
    do:
      declaration(
        :operator,
        "configured operator GitHub ID",
        "agents:moderate",
        verb not in [:get, :head]
      )

  defp policy(%{path: "/api/v3/device/authorizations" <> _path, verb: :post}),
    do:
      declaration(
        :authenticated_api,
        "expiring one-time device secret",
        "device:authorize",
        true
      )

  defp policy(%{path: path, verb: verb})
       when path in ["/api/v3/user", "/api/v3/user/repos", "/api/v3/repository-imports/:id"] and
              verb in [:get, :head],
       do: declaration(:authenticated_api, "first-party bearer token", "forge:read", false)

  defp policy(%{path: "/api/v3/repos/:owner/:repo", verb: verb}) when verb in [:get, :head],
    do:
      declaration(
        :public_read,
        "anonymous or first-party bearer token",
        "forge:repository:read",
        false
      )

  # The deployment control plane has no anonymous surface. Reading a deployment
  # discloses what a repository ships and when, so every route here authenticates
  # a tenant principal, and none of them carries the operator fleet authority
  # behind `/admin/forge`.
  defp policy(%{path: "/api/v3/repos/:owner/:repo/deployment" <> _path, verb: verb})
       when verb in [:get, :head],
       do:
         declaration(
           :authenticated_api,
           "first-party bearer token or workflow grant",
           "deployments:write",
           false
         )

  defp policy(%{path: "/api/v3/repos/:owner/:repo/deployment" <> _path}),
    do:
      declaration(
        :authenticated_api,
        "first-party bearer token or workflow grant",
        "deployments:write",
        true
      )

  defp policy(%{path: "/api/v3/chat/events", verb: verb}) when verb in [:get, :head],
    do: declaration(:authenticated_api, "first-party bearer token", "chat:account", false)

  defp policy(%{path: "/api/v3/chat/turns", verb: :post}),
    do: declaration(:authenticated_api, "first-party bearer token", "chat:account", true)

  defp policy(%{path: "/api/v3/capacity", verb: verb}) when verb in [:get, :head],
    do: declaration(:authenticated_api, "first-party bearer token", "chat:account", false)

  defp policy(%{path: "/api/v3/capacity/matches", verb: :post}),
    do: declaration(:authenticated_api, "first-party bearer token", "chat:account", true)

  defp policy(%{path: path, verb: verb})
       when path in @optional_forge_read_paths and verb in [:get, :head],
       do:
         declaration(
           :public_read,
           "anonymous or first-party bearer token",
           "forge:repository:read",
           false
         )

  defp policy(%{path: path, verb: :post})
       when path in [
              "/api/v3/forum/topics",
              "/api/v3/forum/topics/:topic_id/posts",
              "/api/v3/repos/:owner/:repo/issues",
              "/api/v3/repos/:owner/:repo/issues/:issue_number/comments"
            ],
       do:
         declaration(
           :authenticated_api,
           "first-party human or agent bearer token",
           "forge:write or agent:participate",
           true
         )

  defp policy(%{path: "/api/v3/" <> _path, verb: verb}) when verb in [:get, :head],
    do: declaration(:public_read, "anonymous", "published:forge", false)

  defp policy(%{path: "/api/v3/" <> _path}),
    do: declaration(:authenticated_api, "first-party bearer token", "forge:write", true)

  defp policy(%{path: "/dev/" <> _path}),
    do:
      declaration(:internal_service, "development-only browser", "development:diagnostics", false)

  defp policy(%{plug: OpenAgentsWeb.NotFoundController, verb: verb}) when verb in [:get, :head],
    do: declaration(:public_read, "anonymous", "published:not-found", false)

  defp policy(%{path: path, verb: verb}) do
    cond do
      String.starts_with?(path, "/og/") and verb in [:get, :head] ->
        # Card images are public by construction (they describe only what
        # anonymous pages already show) and mutate nothing.
        declaration(:public_read, "anonymous crawler", "published:og-card", false)

      Enum.any?(@authenticated_browser_prefixes, &String.starts_with?(path, &1)) ->
        declaration(
          :authenticated_browser,
          "active encrypted browser session",
          browser_scope(path),
          browser_mutation?(path, verb)
        )

      tracker_browser_path?(path) ->
        declaration(:authenticated_browser, "active encrypted browser session", "forge:web", true)

      tracker_read_browser_path?(path) and verb in [:get, :head] ->
        # Reading tracker surfaces is public on a public repository. The GET
        # mutates nothing: every write rides the LiveView channel and is
        # re-checked against writability in the view's event handlers.
        declaration(
          :public_read,
          "anonymous visitor or signed-in person",
          "forge:repository:web",
          false
        )

      issue_browser_path?(path) and verb in [:get, :head] ->
        # Reading issues is public on a public repository. The GET mutates
        # nothing: every write rides the LiveView channel and is re-checked
        # against writability in the view's event handlers.
        declaration(
          :public_read,
          "anonymous visitor or signed-in person",
          "forge:issues:web",
          false
        )

      pull_request_browser_path?(path) and verb in [:get, :head] ->
        declaration(
          :public_read,
          "anonymous visitor or signed-in person",
          "forge:pull-requests:web",
          false
        )

      repository_browser_path?(path) and verb in [:get, :head] ->
        declaration(
          :public_read,
          "anonymous or active repository member session",
          "forge:repository:web",
          false
        )

      true ->
        %{class: :unclassified, principal: nil, scope: nil, mutation: mutation_verb?(path)}
    end
  end

  defp declaration(class, principal, scope, mutation) do
    %{class: class, principal: principal, scope: scope, mutation: mutation}
  end

  defp browser_scope("/api/tokens" <> _path), do: "api-token:self"
  defp browser_scope("/api/computers" <> _path), do: "computer:self"
  defp browser_scope("/api/computer-agent-jobs/" <> _path), do: "computer-job:self"
  defp browser_scope("/voice/" <> _path), do: "voice:self"
  defp browser_scope("/data" <> _path), do: "data:self"
  defp browser_scope("/artifact-catalog"), do: "artifact-catalog:read"
  defp browser_scope("/memory/" <> _path), do: "memory:self"
  defp browser_scope("/github/connection"), do: "github-tools:self"
  defp browser_scope("/settings/api-tokens"), do: "api-token:self"
  defp browser_scope(_path), do: "product:self"

  defp browser_mutation?(path, :get),
    do: path in ["/sarah", "/memory", "/computers", "/settings/api-tokens"]

  defp browser_mutation?(_path, _verb), do: true

  defp tracker_browser_path?(path) do
    String.match?(path, ~r{\A/:owner/:repo/(issues/new|assignees|members)\z})
  end

  defp tracker_read_browser_path?(path) do
    path in [
      "/:owner/:repo/labels",
      "/:owner/:repo/milestones",
      "/:owner/:repo/projects",
      "/:owner/:repo/projects/:number"
    ]
  end

  # The issue index and detail pages live in their own public-read session;
  # `issues/new` above stays behind sign-in because filing needs an author.
  defp issue_browser_path?(path) do
    path == "/:owner/:repo/issues" or
      String.match?(path, ~r{\A/:owner/:repo/issues/:number\z})
  end

  defp pull_request_browser_path?(path) do
    path == "/:owner/:repo/pulls" or
      String.match?(path, ~r{\A/:owner/:repo/pulls/:number\z})
  end

  defp repository_browser_path?(path) do
    path == "/:owner/:repo" or
      String.starts_with?(path, [
        "/:owner/:repo/commit/",
        "/:owner/:repo/tree/",
        "/:owner/:repo/blob/"
      ])
  end

  defp mutation_verb?(_path), do: true
end
