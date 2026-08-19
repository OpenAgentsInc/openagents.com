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
      live "/components", ComponentsLive, :index
      live "/components/icons", IconIndexLive, :index
    end

    post "/auth/github", AuthController, :start
    get "/auth/github/callback", AuthController, :callback
    delete "/logout", AuthController, :logout
  end

  scope "/", OpenAgentsWeb do
    pipe_through [:browser, :authenticated]

    live_session :authenticated,
      on_mount: [{OpenAgentsWeb.UserAuth, :ensure_authenticated}] do
      live "/chat", ChatLive, :index

      live "/:owner/:repo/issues/new", IssueNewLive, :new
      live "/:owner/:repo/issues/:number", IssueShowLive, :show
      live "/:owner/:repo/issues", IssueIndexLive, :index

      live "/:owner/:repo/labels", LabelIndexLive, :index
      live "/:owner/:repo/milestones", MilestoneIndexLive, :index
      live "/:owner/:repo/assignees", AssigneeIndexLive, :index

      live "/:owner/:repo/projects/:number", ProjectShowLive, :show
      live "/:owner/:repo/projects", ProjectIndexLive, :index
    end
  end

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
