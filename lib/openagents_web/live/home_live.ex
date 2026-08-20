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
      <section class="flex min-h-[60vh] items-center justify-center px-4">
        <div class="text-center">
          <div class="max-w-4xl space-y-6">
            <h1 class="text-5xl md:text-7xl font-bold tracking-tight">
              The Agent Forge
            </h1>
            <p class="text-xl md:text-2xl text-muted-foreground">
              Purpose-built for planning and shipping issues. Designed for the agent era.
            </p>
            <div id="github-tools" class="flex flex-wrap justify-center gap-4">
              <%= if @current_user do %>
                <.button
                  id="home-cta-create"
                  navigate={~p"/OpenAgentsInc/openagents.com/issues/new"}
                  variant={:primary}
                >
                  Create new issue
                </.button>
                <.button id="home-cta-browse" navigate={~p"/OpenAgentsInc/openagents.com/issues"}>
                  View issues
                </.button>
              <% else %>
                <.form
                  for={%{}}
                  as={:auth}
                  action={~p"/auth/github?github_tools=enabled"}
                  method="post"
                  class="m-0 max-w-xl space-y-3"
                >
                  <p id="github-tools-disclosure" class="text-sm text-muted-foreground">
                    OpenAgents will retain an encrypted GitHub grant with the <code>repo</code>
                    scope. GitHub makes that scope read/write even though OpenAgents currently
                    exposes it only to bounded repository-reading tools. You can revoke the
                    grant from the account menu at any time.
                  </p>
                  <.button type="submit" variant={:primary} id="home-cta-signin">
                    Sign in and enable GitHub tools
                  </.button>
                </.form>
              <% end %>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
