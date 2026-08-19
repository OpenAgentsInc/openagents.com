defmodule OpenAgentsWeb.HomeLive do
  @moduledoc """
  Marketing-style homepage with a hero.
  """
  use OpenAgentsWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <section class="hero min-h-[60vh]">
        <div class="hero-content text-center">
          <div class="max-w-4xl space-y-6">
            <h1 class="text-5xl md:text-7xl font-bold tracking-tight">
              The agent forge
            </h1>
            <p class="text-xl md:text-2xl text-base-content/70">
              Purpose-built for planning and shipping issues. Designed for the agent era.
            </p>
            <div class="flex flex-wrap justify-center gap-4">
              <%= if @current_user do %>
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
              <% else %>
                <.form for={%{}} as={:auth} action={~p"/auth/github"} method="post" class="m-0">
                  <.button type="submit" variant="primary" id="home-cta-signin">
                    Sign in with GitHub
                  </.button>
                </.form>
              <% end %>
            </div>
          </div>
        </div>
      </section>

      <%!--
      <div class="flex justify-center -mt-20 mb-20 px-4">
        <div class="mockup-browser border bg-base-200 w-full max-w-4xl">
          <div class="mockup-browser-toolbar">
            <div class="input">openagents.com/OpenAgents/openagents/issues</div>
          </div>
          <div class="p-6">
            <div class="card bg-base-100 border border-base-300 mt-4">
              <div class="card-body">
                <div class="flex items-start gap-4">
                  <.icon name="hero-exclamation-circle" class="size-6 text-success shrink-0" />
                  <div class="flex-1">
                    <h2 class="text-2xl font-bold">
                      Issue preview
                      <span class="text-base-content/50 text-lg font-normal">#1</span>
                    </h2>
                    <p class="text-sm text-base-content/70 mt-1">
                      Opened on Aug 19, 2026 by OpenAgents
                    </p>
                    <div class="flex flex-wrap gap-1 mt-3">
                      <span class="badge badge-sm">preview</span>
                    </div>
                  </div>
                </div>
                <p class="whitespace-pre-wrap mt-4 text-base-content/90">
                  This is a placeholder for the live issue preview.
                </p>
                <div class="card-actions justify-end mt-4">
                  <.button navigate={~p"/OpenAgents/openagents/issues/1"} variant="primary">
                    Open issue
                  </.button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
      --%>
    </Layouts.app>
    """
  end
end
