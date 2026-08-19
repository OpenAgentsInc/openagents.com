defmodule OpenAgentsWeb.Router do
  use OpenAgentsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OpenAgentsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", OpenAgentsWeb do
    pipe_through :browser

    get "/", PageController, :home
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
