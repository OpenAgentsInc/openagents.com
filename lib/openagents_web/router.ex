defmodule OpenAgentsWeb.Router do
  use OpenAgentsWeb, :router

  import OpenAgentsWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OpenAgentsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug :require_authenticated_user
  end

  scope "/", OpenAgentsWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [{OpenAgentsWeb.UserAuth, :mount_current_user}] do
      live "/", HomeLive, :index
      live "/status", NetworkStatusLive, :index
      live "/changelog", ChangelogLive, :index
      live "/leaderboard", LeaderboardLive, :index
      live "/code/:owner/:repo", CodeRepoLive, :index
      live "/code/:owner/:repo/blob/*path", CodeBlobLive, :index
      live "/code/:owner/:repo/commit/:sha", CodeCommitLive, :index
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
    get "/auth/github/callback", AuthController, :callback
    delete "/logout", AuthController, :logout
    get "/healthz", HealthController, :show
  end

  scope "/", OpenAgentsWeb do
    pipe_through [:browser, :authenticated]

    live_session :authenticated,
      on_mount: [{OpenAgentsWeb.UserAuth, :ensure_authenticated}] do
      live "/chat", ChatLive, :index
      live "/computers", ComputersLive, :index
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

    get "/machines", ComputersController, :index
    get "/api/computers", ComputersController, :index
    post "/api/computers/pairings/:id/approve", ComputersController, :approve_pairing
    delete "/api/computers/:id", ComputersController, :delete
    post "/api/computers/:machine_id/agent-jobs", ComputerAgentJobsController, :create
    get "/api/computer-agent-jobs/:id", ComputerAgentJobsController, :show
    delete "/api/computer-agent-jobs/:id", ComputerAgentJobsController, :delete

    get "/api/changelog", ChangelogController, :show
    get "/api/status", NetworkStatusController, :show
    get "/memory/export", MemoryExportController, :show
  end

  forward "/git", OpenAgents.Forge.GitHTTP

  scope "/api/v3", OpenAgentsWeb do
    pipe_through :api

    resources "/repos/:owner/:repo/issues", IssueController,
      only: [:index, :create, :show, :update],
      param: "issue_number"

    resources "/repos/:owner/:repo/issues/:issue_number/comments", CommentController,
      only: [:index, :create]

    resources "/repos/:owner/:repo/issues/comments", CommentController,
      only: [:show, :update, :delete]

    resources "/repos/:owner/:repo/issues/:issue_number/labels", IssueLabelController,
      only: [:index, :create]

    delete "/repos/:owner/:repo/issues/:issue_number/labels/:name",
           IssueLabelController,
           :delete

    resources "/repos/:owner/:repo/issues/:issue_number/assignees", IssueAssigneeController,
      only: [:index, :create]

    delete "/repos/:owner/:repo/issues/:issue_number/assignees",
           IssueAssigneeController,
           :delete

    resources "/repos/:owner/:repo/labels", LabelController,
      only: [:index, :create, :show, :update, :delete],
      param: "name"

    resources "/repos/:owner/:repo/milestones", MilestoneController,
      only: [:index, :create, :show, :update, :delete],
      param: "milestone_number"

    get "/repos/:owner/:repo/assignees", AssigneeController, :index
    get "/repos/:owner/:repo/assignees/:assignee", AssigneeController, :show

    get "/users/:username/projectsV2", ProjectController, :index
    post "/:owner/projectsV2", ProjectController, :create
    get "/users/:username/projectsV2/:project_number", ProjectController, :show
    get "/users/:username/projectsV2/:project_number/items", ProjectController, :items
    post "/users/:username/projectsV2/:project_number/items", ProjectController, :create_item

    patch "/users/:username/projectsV2/:project_number/items/:item_id",
          ProjectController,
          :update_item

    get "/users/:username/projectsV2/:project_number/fields", ProjectController, :fields
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
