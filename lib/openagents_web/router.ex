defmodule OpenAgentsWeb.Router do
  use OpenAgentsWeb, :router

  import OpenAgentsWeb.UserAuth

  # The account segment public forge URLs live under, mirroring GitHub.
  @forge_url_owner Application.compile_env(:openagents, :forge_url_owner, "OpenAgentsInc")

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OpenAgentsWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; base-uri 'self'; connect-src 'self' ws: wss:; frame-ancestors 'none'; img-src 'self' data: https://avatars.githubusercontent.com; object-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'",
      "permissions-policy" => "microphone=(self)"
    }

    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
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
    plug OpenAgentsWeb.Plugs.ApiTokenAuth, scope: "forge:write"
  end

  pipeline :status_probe_compat do
    plug OpenAgentsWeb.Plugs.StatusProbeCompat
  end

  pipeline :authenticated do
    plug :put_no_store
    plug :require_authenticated_user
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
    end

    post "/auth/github", AuthController, :start
    get "/auth/github/callback", AuthController, :callback, log: false
    delete "/logout", AuthController, :logout
    get "/healthz", HealthController, :show
  end

  # The public forge web UI (TRANSPARENCY-001), addressed exactly the way the
  # GitHub URL it replaces is:
  # openagents.com/OpenAgentsInc/openagents.com/blob/main/README.md.
  #
  # The owner is a LITERAL scope segment, not a `:owner` pattern: a wildcard
  # first segment would match every two-segment path on the domain (/dev/ui,
  # a future /foo/bar) and shadow it. Scoping to the owning account keeps the
  # GitHub-identical URL while touching nothing else.
  scope "/#{@forge_url_owner}", OpenAgentsWeb do
    pipe_through :browser

    live_session :public_code,
      on_mount: [{OpenAgentsWeb.UserAuth, :mount_current_user}] do
      live "/:repo", CodeRepoLive, :index
      live "/:repo/commit/:sha", CodeCommitLive, :index
      live "/:repo/blob/:ref/*path", CodeBlobLive, :index
    end
  end

  scope "/", OpenAgentsWeb do
    pipe_through [:browser, :authenticated]

    live_session :authenticated,
      on_mount: [{OpenAgentsWeb.UserAuth, :ensure_authenticated}] do
      live "/chat", ChatLive, :index
      live "/computers", ComputersLive, :index
      live "/settings/api-tokens", ApiTokensLive, :index
      live "/admin", AdminLive, :index
      live "/admin/forge", AdminForgeLive, :index

      live "/:owner/:repo/issues/new", IssueNewLive, :new
      live "/:owner/:repo/issues/:number", IssueShowLive, :show
      live "/:owner/:repo/issues", IssueIndexLive, :index

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

  forward "/git", OpenAgents.Forge.GitHTTP

  scope "/", OpenAgentsWeb do
    pipe_through :api

    get "/api/status", NetworkStatusController, :show
    get "/api/changelog", ChangelogController, :show

    post "/controller/pairings", ControllerPairingController, :create
    get "/controller/pairings/:id", ControllerPairingController, :show
    post "/api/inference/proxy", InferenceProxyController, :create
  end

  scope "/api/v3", OpenAgentsWeb do
    pipe_through :api

    get "/repos/:owner/:repo/issues", IssueController, :index
    get "/repos/:owner/:repo/issues/:issue_number", IssueController, :show
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
    get "/users/:username/projectsV2", ProjectController, :index
    get "/users/:username/projectsV2/:project_number", ProjectController, :show
    get "/users/:username/projectsV2/:project_number/items", ProjectController, :items
    get "/users/:username/projectsV2/:project_number/fields", ProjectController, :fields
  end

  scope "/api/v3", OpenAgentsWeb do
    pipe_through :forge_write_api

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
    post "/:owner/projectsV2", ProjectController, :create
    post "/users/:username/projectsV2/:project_number/items", ProjectController, :create_item

    patch "/users/:username/projectsV2/:project_number/items/:item_id",
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
end
