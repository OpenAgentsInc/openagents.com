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
            <div class="flex flex-wrap justify-center gap-4">
              <%= if @current_user do %>
                <.button
                  id="home-cta-create"
                  navigate={~p"/OpenAgents/openagents/issues/new"}
                  variant={:primary}
                >
                  Create new issue
                </.button>
                <.button id="home-cta-browse" navigate={~p"/OpenAgents/openagents/issues"}>
                  View issues
                </.button>
              <% else %>
                <.form for={%{}} as={:auth} action={~p"/auth/github"} method="post" class="m-0">
                  <.button type="submit" variant={:primary} id="home-cta-signin">
                    Sign in with GitHub
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
