defmodule OpenAgentsWeb.HomeLive do
  @moduledoc """
  Marketing-style homepage with a hero and a product preview card.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_scope, nil)
     |> assign(:demo_issue, Issues.list_issues(state: "open") |> List.first())}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <section class="hero min-h-[60vh]">
        <div class="hero-content text-center">
          <div class="max-w-4xl space-y-6">
            <h1 class="text-5xl md:text-7xl font-bold tracking-tight">
              The agent forge for teams and agents
            </h1>
            <p class="text-xl md:text-2xl text-base-content/70">
              Purpose-built for planning and shipping issues. Designed for the agent era.
            </p>
            <div class="flex flex-wrap justify-center gap-4">
              <.button
                id="home-cta-create"
                navigate={~p"/OpenAgents/openagents/issues/new"}
                variant="primary"
              >
                Create new issue
              </.button>
              <.button id="home-cta-browse" navigate={~p"/OpenAgents/openagents/issues"}>
                View issues
              </.button>
            </div>
          </div>
        </div>
      </section>

      <div class="flex justify-center -mt-20 mb-20 px-4">
        <div class="mockup-browser border bg-base-200 w-full max-w-4xl">
          <div class="mockup-browser-toolbar">
            <div class="input">openagents.com/OpenAgents/openagents/issues</div>
          </div>
          <div class="p-6">
            <%= if @demo_issue do %>
              <.repo_header owner="OpenAgents" repo="openagents" active="issues" />
              <div class="card bg-base-100 border border-base-300 mt-4">
                <div class="card-body">
                  <div class="flex items-start gap-4">
                    <.icon name="hero-exclamation-circle" class="size-6 text-success shrink-0" />
                    <div class="flex-1">
                      <h2 class="text-2xl font-bold">
                        {@demo_issue.title}
                        <span class="text-base-content/50 text-lg font-normal">
                          #{@demo_issue.number}
                        </span>
                      </h2>
                      <p class="text-sm text-base-content/70 mt-1">
                        Opened on {Calendar.strftime(@demo_issue.inserted_at, "%b %d, %Y")} by {(@demo_issue.user &&
                                                                                                   @demo_issue.user[
                                                                                                     "login"
                                                                                                   ]) ||
                          "anonymous"}
                      </p>
                      <div class="flex flex-wrap gap-1 mt-3">
                        <%= for label <- @demo_issue.labels || [] do %>
                          <span
                            class="badge badge-sm"
                            style={"background-color: ##{label["color"]}; color: #000;"}
                          >
                            {label["name"]}
                          </span>
                        <% end %>
                      </div>
                    </div>
                  </div>
                  <p class="whitespace-pre-wrap mt-4 text-base-content/90">
                    {@demo_issue.body || "No description provided."}
                  </p>
                  <div class="card-actions justify-end mt-4">
                    <.button
                      navigate={~p"/OpenAgents/openagents/issues/#{@demo_issue.number}"}
                      variant="primary"
                    >
                      Open issue
                    </.button>
                  </div>
                </div>
              </div>
            <% else %>
              <div class="alert alert-info">
                <.icon name="hero-information-circle" class="size-5" />
                <span>No open issues to preview. Create one to get started.</span>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
