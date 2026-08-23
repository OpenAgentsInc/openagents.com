defmodule OpenAgentsWeb.Router do
  use OpenAgentsWeb, :router

  import OpenAgentsWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OpenAgentsWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "permissions-policy" => "microphone=(self)"
    }

    plug OpenAgentsWeb.Plugs.ContentSecurityPolicy

    plug OpenAgentsWeb.Plugs.PostHogBootstrap

    plug :fetch_current_user
    plug OpenAgentsWeb.Plugs.SidebarSections
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
  end

  pipeline :authenticated_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_current_user
    plug :put_no_store
    plug :protect_from_forgery
    plug :require_authenticated_api_user
  end

  pipeline :forge_write_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.ApiTokenAuth, scope: "forge:write"
  end

  pipeline :chat_account_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.ApiTokenAuth, scope: "chat:account"
  end

  pipeline :optional_forge_api do
    plug :accepts, ["json"]
    plug OpenAgentsWeb.Plugs.RequestOrigin
    plug OpenAgentsWeb.Plugs.OptionalApiTokenAuth, scope: "forge:write"
  end

  pipeline :forge_git do
    plug OpenAgentsWeb.Plugs.ForgeGitAuth
  end

  pipeline :status_probe_compat do
    plug OpenAgentsWeb.Plugs.StatusProbeCompat
  end

  pipeline :authenticated do
    plug :put_no_store
    plug :require_authenticated_user
  end

  pipeline :operator do
    plug :require_admin_user
  end

  scope "/", OpenAgentsWeb do
    pipe_through [:status_probe_compat, :browser]

    live_session :public,
      on_mount: [{OpenAgentsWeb.UserAuth, :mount_current_user}] do
      live "/", HomeLive, :index
      live "/status", NetworkStatusLive, :index
      live "/changelog", ChangelogLive, :index
      live "/leaderboard", LeaderboardLive, :index
    end

    # `/components/icons` must stay ahead of `/components/:slug` so the literal
    # route wins; the catalog's own slugs never include "icons".
    live_session :components,
      layout: {OpenAgentsWeb.Layouts, :components},
      on_mount: [{OpenAgentsWeb.UserAuth, :mount_current_user}] do
      live "/components", ComponentsLive, :index
      live "/components/icons", IconIndexLive, :index
      live "/components/:slug", ComponentsLive, :show
    end

    live_session :docs,
      layout: {OpenAgentsWeb.Layouts, :docs},
      on_mount: [{OpenAgentsWeb.UserAuth, :mount_current_user}] do
      live "/docs", DocsLive, :index
      live "/docs/:slug", DocsLive, :show
    end

    post "/auth/github", AuthController, :start
    get "/auth/github/callback", AuthController, :callback, log: false
    delete "/logout", AuthController, :logout
  end

  scope "/", OpenAgentsWeb do
    pipe_through [:browser, :authenticated]

    live_session :authenticated,
      on_mount: [{OpenAgentsWeb.UserAuth, :ensure_authenticated}] do
      live "/sarah", ChatLive, :index
      live "/memory", MemoryLive, :index
      live "/computers", ComputersLive, :index
      live "/settings/api-tokens", ApiTokensLive, :index
      live "/device", DeviceAuthorizationLive, :show
      live "/repositories", RepositoryIndexLive, :index
      live "/repositories/new", RepositoryNewLive, :new
      live "/repositories/import/github", RepositoryImportLive, :new

      # The sidebar's global surfaces. They are workspace-wide by construction:
      # each reads through the repository visibility predicate rather than
      # through a repository the URL names, so what they show never depends on
      # which page you arrived from.
      live "/issues", IssueWorkspaceLive, :index
      live "/projects", ProjectWorkspaceLive, :index
      live "/forum", ForumHomeLive, :index
      live "/forum/f/:slug", ForumBoardLive, :show
      live "/forum/t/:id", ForumTopicLive, :show
      live "/forum/claim", ForumClaimLive, :new

      live "/:owner/:repo/issues/new", IssueNewLive, :new

      live "/:owner/:repo/members", MemberIndexLive, :index
      live "/:owner/:repo/labels", LabelIndexLive, :index
      live "/:owner/:repo/milestones", MilestoneIndexLive, :index
      live "/:owner/:repo/assignees", AssigneeIndexLive, :index

      live "/:owner/:repo/projects/:number", ProjectShowLive, :show
      live "/:owner/:repo/projects", ProjectIndexLive, :index
    end

    post "/voice/calls", VoiceCallController, :create
    post "/voice/calls/interrupt", VoiceCallController, :interrupt
    post "/voice/telemetry", VoiceTelemetryController, :create
    post "/voice/calls/recording", VoiceRecordingController, :create
    post "/voice/calls/recording/complete", VoiceRecordingController, :complete
    delete "/voice/calls", VoiceCallController, :delete

    get "/data/export", DataController, :show
    get "/data/export/atif", DataController, :export_atif
    delete "/data", DataController, :delete
    delete "/data/reset", DataController, :reset

    # The legacy Computers path is a permanent-ish redirect, not a second
    # render of the surface: it must drop its query (an OAuth `code=` must
    # never survive into the canonical URL).
    get "/machines", LegacyMachinesController, :show

    get "/memory/export", MemoryExportController, :show
    delete "/github/connection", AuthController, :disconnect
  end

  # The chat surface is a placeholder for the upcoming product, and it is
  # operator-only: the gate runs twice, as a plug on the initial request and as
  # an on_mount hook on the LiveView, the same belt-and-suspenders the /admin
  # scope uses. Everyone else is redirected to home rather than shown a login
  # wall for a page they cannot open.
  scope "/", OpenAgentsWeb do
    pipe_through [:browser, :authenticated, :operator]

    live_session :operator_chat,
      on_mount: [
        {OpenAgentsWeb.UserAuth, :ensure_authenticated},
        {OpenAgentsWeb.UserAuth, :ensure_admin}
      ] do
      live "/chat", ChatPlaceholderLive, :index
    end
  end

  # Reading issues is a public activity on a public repository, the way code
  # browsing already is, so this session runs behind plain :browser and mounts
  # whoever is signed in. Each view decides what an anonymous visitor may do,
  # and every write re-checks authority at the server. The scope comes after
  # the authenticated one so the literal `new` segment keeps winning over
  # `:number`.
  scope "/", OpenAgentsWeb do
    pipe_through :browser

    live_session :forge_issues,
      on_mount: [{OpenAgentsWeb.UserAuth, :mount_current_user}] do
      live "/:owner/:repo/issues/:number", IssueShowLive, :show
      live "/:owner/:repo/issues", IssueIndexLive, :index
    end
  end

  scope "/api", OpenAgentsWeb do
    pipe_through :authenticated_api

    get "/tokens", ApiTokenController, :index
    post "/tokens", ApiTokenController, :create
    delete "/tokens/:id", ApiTokenController, :delete

    get "/computers", ComputersController, :index
    post "/computers/pairings/:id/approve", ComputersController, :approve_pairing
    delete "/computers/:id", ComputersController, :delete
    post "/computers/:machine_id/agent-jobs", ComputerAgentJobsController, :create
    get "/computer-agent-jobs/:id", ComputerAgentJobsController, :show
    delete "/computer-agent-jobs/:id", ComputerAgentJobsController, :delete
  end

  scope "/admin", OpenAgentsWeb do
    pipe_through [:browser, :authenticated, :operator]

    live_session :operator,
      on_mount: [
        {OpenAgentsWeb.UserAuth, :ensure_authenticated},
        {OpenAgentsWeb.UserAuth, :ensure_admin}
      ] do
      live "/", AdminLive, :index
      live "/analytics", AdminAnalyticsLive, :index
      live "/forge", AdminForgeLive, :index
      live "/recordings", AdminRecordingsLive, :index
      live "/scv/accounts", AdminScvAccountsLive, :index
      live "/forum/claims", AdminForumLinksLive, :index
    end

    get "/recordings/:id/audio", AdminRecordingController, :show
  end

  scope "/" do
    pipe_through :forge_git

    get "/:owner/:repo/info/refs", OpenAgents.Forge.GitHTTP, []
    post "/:owner/:repo/git-upload-pack", OpenAgents.Forge.GitHTTP, []
    post "/:owner/:repo/git-receive-pack", OpenAgents.Forge.GitHTTP, []
  end

  # Keep existing remotes operational while every newly issued clone URL uses
  # the canonical GitHub-shaped /:owner/:repo.git path.
  scope "/git" do
    pipe_through :forge_git
    forward "/", OpenAgents.Forge.GitHTTP
  end

  scope "/", OpenAgentsWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/healthz", HealthController, :show
    get "/api/status", NetworkStatusController, :show
    get "/api/changelog", ChangelogController, :show
    get "/api/contracts/repositories-v1.json", ApiContractController, :repositories_v1

    post "/controller/pairings", ControllerPairingController, :create
    get "/controller/pairings/:id", ControllerPairingController, :show
    post "/api/inference/proxy", InferenceProxyController, :create
  end

  scope "/api/v3", OpenAgentsWeb do
    pipe_through :api

    post "/device/authorizations", DeviceAuthorizationController, :create
    post "/device/authorizations/token", DeviceAuthorizationController, :token

    get "/repos/:owner/:repo/issues/:issue_number/comments", CommentController, :index
    get "/repos/:owner/:repo/issues/comments/:id", CommentController, :show
    get "/repos/:owner/:repo/issues/:issue_number/labels", IssueLabelController, :index
    get "/repos/:owner/:repo/issues/:issue_number/assignees", IssueAssigneeController, :index
    get "/repos/:owner/:repo/labels", LabelController, :index
    get "/repos/:owner/:repo/labels/:name", LabelController, :show
    get "/repos/:owner/:repo/milestones", MilestoneController, :index
    get "/repos/:owner/:repo/milestones/:milestone_number", MilestoneController, :show
    get "/repos/:owner/:repo/assignees", AssigneeController, :index
    get "/repos/:owner/:repo/assignees/:assignee", AssigneeController, :show
  end

  scope "/api/v3", OpenAgentsWeb do
    pipe_through :chat_account_api

    get "/chat/events", ChatTurnController, :index
    post "/chat/turns", ChatTurnController, :create
  end

  scope "/api/v3", OpenAgentsWeb do
    pipe_through :forge_write_api

    # Forum writes. Reads are public and live in the optional-auth scope.
    post "/forum/topics", ForumApiController, :create_topic
    post "/forum/topics/:topic_id/posts", ForumApiController, :create_post
    post "/forum/claims", ForumApiController, :create_claim
    get "/forum/claims", ForumApiController, :list_claims
  end

  scope "/api/v3", OpenAgentsWeb do
    pipe_through :optional_forge_api

    get "/repos/:owner/:repo", RepositoryController, :show
    get "/repos/:owner/:repo/issues", IssueController, :index
    get "/repos/:owner/:repo/issues/:issue_number", IssueController, :show
    get "/repos/:owner/:repo/projectsV2", ProjectController, :index
    get "/repos/:owner/:repo/projectsV2/:project_number", ProjectController, :show
    get "/repos/:owner/:repo/projectsV2/:project_number/items", ProjectController, :items
    get "/repos/:owner/:repo/projectsV2/:project_number/fields", ProjectController, :fields

    # The forum reads. Posting and claiming live behind the write scope.
    get "/forum", ForumApiController, :boards
    get "/forum/topics", ForumApiController, :topics
    get "/forum/topics/:id", ForumApiController, :show_topic
  end

  scope "/api/v3", OpenAgentsWeb do
    pipe_through :forge_write_api

    get "/user", ForgeUserController, :show
    get "/user/repos", RepositoryController, :index
    post "/user/repos", RepositoryController, :create_user
    post "/orgs/:org/repos", RepositoryController, :create_organization
    delete "/repos/:owner/:repo", RepositoryController, :delete
    post "/user/repos/imports", RepositoryImportController, :create_user
    post "/orgs/:org/repos/imports", RepositoryImportController, :create_organization
    get "/repository-imports/:id", RepositoryImportController, :show

    post "/repos/:owner/:repo/issues", IssueController, :create
    put "/repos/:owner/:repo/issues/:issue_number", IssueController, :update
    patch "/repos/:owner/:repo/issues/:issue_number", IssueController, :update
    post "/repos/:owner/:repo/issues/:issue_number/comments", CommentController, :create
    put "/repos/:owner/:repo/issues/comments/:id", CommentController, :update
    patch "/repos/:owner/:repo/issues/comments/:id", CommentController, :update
    delete "/repos/:owner/:repo/issues/comments/:id", CommentController, :delete
    post "/repos/:owner/:repo/issues/:issue_number/labels", IssueLabelController, :create
    delete "/repos/:owner/:repo/issues/:issue_number/labels/:name", IssueLabelController, :delete
    post "/repos/:owner/:repo/issues/:issue_number/assignees", IssueAssigneeController, :create
    delete "/repos/:owner/:repo/issues/:issue_number/assignees", IssueAssigneeController, :delete
    post "/repos/:owner/:repo/labels", LabelController, :create
    put "/repos/:owner/:repo/labels/:name", LabelController, :update
    patch "/repos/:owner/:repo/labels/:name", LabelController, :update
    delete "/repos/:owner/:repo/labels/:name", LabelController, :delete
    post "/repos/:owner/:repo/milestones", MilestoneController, :create
    put "/repos/:owner/:repo/milestones/:milestone_number", MilestoneController, :update
    patch "/repos/:owner/:repo/milestones/:milestone_number", MilestoneController, :update
    delete "/repos/:owner/:repo/milestones/:milestone_number", MilestoneController, :delete
    post "/repos/:owner/:repo/projectsV2", ProjectController, :create

    post "/repos/:owner/:repo/projectsV2/:project_number/items",
         ProjectController,
         :create_item

    post "/repos/:owner/:repo/projectsV2/:project_number/fields",
         ProjectController,
         :create_field

    patch "/repos/:owner/:repo/projectsV2/:project_number/items/:item_id",
          ProjectController,
          :update_item
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:openagents, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: OpenAgentsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Open Graph card images: content-versioned, HMAC-signed, public-only.
  # The version segment is advisory cache-busting; the signature gates the
  # endpoint against third-party rendering abuse; private and missing
  # repositories are indistinguishable 404s.
  scope "/og", OpenAgentsWeb do
    get "/static/card.png", OgImageController, :static
    get "/v/:version/repos/:owner/:repo", OgImageController, :repo
    get "/v/:version/repos/:owner/:repo/issues/:number", OgImageController, :issue
    get "/v/:version/repos/:owner/:repo/commit/:sha", OgImageController, :commit
    get "/v/:version/repos/:owner/:repo/blob/:ref/*path", OgImageController, :blob
  end

  # Keep repository-shaped routes last. Every fixed product, API, operator,
  # Git, and development route above wins before a GitHub-backed namespace can
  # be interpreted from the first path segment.
  scope "/", OpenAgentsWeb do
    pipe_through :browser

    for reserved <- OpenAgents.Repositories.Namespace.reserved_slugs() do
      get "/#{reserved}/*path", NotFoundController, :show
    end
  end

  scope "/", OpenAgentsWeb do
    pipe_through :browser

    live_session :repository_code,
      on_mount: [{OpenAgentsWeb.UserAuth, :mount_current_user}] do
      live "/:owner/:repo", CodeRepoLive, :index
      live "/:owner/:repo/commit/:sha", CodeCommitLive, :index
      live "/:owner/:repo/tree/:ref/*path", CodeTreeLive, :index
      live "/:owner/:repo/blob/:ref/*path", CodeBlobLive, :index
    end
  end
end
