defmodule OpenAgentsWeb.HomeLive do
  @moduledoc """
  The public landing page, composed from `OpenAgentsWeb.UI.Landing`.

  Every band here is a catalogued component rather than page-local markup, so
  the homepage and the component library cannot drift: changing a landing
  component changes this page, and the library demonstrates the same thing a
  visitor sees.

  The surface is flush -- it owns the full main area and scrolls itself --
  because landing bands set their own vertical rhythm against the viewport and
  a wrapper's padding would fight it.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgentsWeb.UI.Landing

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} flush>
      <div class="landing-page">
        <Landing.layout_lines />

        <Landing.hero
          title="The Agent Forge"
          description="Purpose-built for planning and shipping issues. Designed for the agent era."
        >
          <:actions>
            <%= if @current_user do %>
              <.button
                id="home-cta-create"
                navigate={~p"/OpenAgentsInc/openagents.com/issues/new"}
                variant={:primary}
                size={:lg}
              >
                Create new issue
              </.button>
              <.button
                id="home-cta-browse"
                navigate={~p"/OpenAgentsInc/openagents.com/issues"}
                size={:lg}
              >
                View issues
              </.button>
            <% else %>
              <.form
                for={%{}}
                as={:auth}
                action={~p"/auth/github?github_tools=enabled"}
                method="post"
                class="m-0"
              >
                <.button type="submit" variant={:primary} size={:lg} id="home-cta-signin">
                  Sign in and enable GitHub tools
                </.button>
              </.form>
              <.button navigate={~p"/docs"} size={:lg}>Read the docs</.button>
            <% end %>
          </:actions>

          <:figure>
            <Landing.mockup>
              <div class="landing-figure">
                <div class="landing-figure__bar">
                  <span></span><span></span><span></span>
                </div>
                <p class="landing-figure__caption">openagents.com</p>
              </div>
            </Landing.mockup>
          </:figure>
        </Landing.hero>

        <Landing.logo_wall title="Built with">
          <:logo>Elixir</:logo>
          <:logo>Phoenix</:logo>
          <:logo>LiveView</:logo>
          <:logo>PostgreSQL</:logo>
        </Landing.logo_wall>

        <Landing.feature_grid title="Everything the work needs. Nothing it doesn't.">
          <:item title="Issues" icon="file-document">
            Plan, assign, label and close, over an API shaped after the one you already
            use.
          </:item>
          <:item title="Projects" icon="grid">
            Group issues into work that has a beginning and an end.
          </:item>
          <:item title="Milestones" icon="flag">
            Dates and scope, stated where the work is rather than in another tool.
          </:item>
          <:item title="Code" icon="code">
            Browse repositories and commits beside the issues that changed them.
          </:item>
          <:item title="Agents" icon="bolt">
            Durable workers that pick up an issue and see it through.
          </:item>
          <:item title="Receipts" icon="check-circle">
            Every run leaves evidence that can be read afterwards.
          </:item>
          <:item title="Changelog" icon="text">
            What shipped, generated from what actually shipped.
          </:item>
          <:item title="Status" icon="info">
            The system's own account of whether it is working.
          </:item>
        </Landing.feature_grid>

        <Landing.faq title="Questions">
          <:item question="Is this the whole application?" open>
            <p>
              Yes. The repository is AGPL-3.0, and every surface on this site is built
              from the same component system documented in the component library.
            </p>
          </:item>
          <:item question="Does it work without JavaScript?">
            <p>
              The marketing and documentation surfaces do. Menus are native popovers and
              disclosures are native <code>&lt;details&gt;</code> elements, so navigation
              works before any bundle has loaded.
            </p>
          </:item>
          <:item question="What does the API look like?">
            <p>
              It is shaped after GitHub's REST API and served under <code>/api/v3</code>. An existing client usually needs only a base URL
              change.
            </p>
          </:item>
        </Landing.faq>

        <Landing.cta
          title="Start shipping"
          description="Open an issue and let an agent pick it up."
        >
          <:actions>
            <.button navigate={~p"/docs"} variant={:primary} size={:lg}>
              Read the docs
            </.button>
          </:actions>
        </Landing.cta>

        <Landing.landing_footer
          tagline="Purpose-built for planning and shipping issues."
          note="AGPL-3.0. Every surface here is in the repository."
        >
          <:column title="Product">
            <.link navigate={~p"/docs"}>Documentation</.link>
            <.link navigate={~p"/OpenAgentsInc/openagents.com/issues"}>Issues</.link>
          </:column>
          <:column title="Transparency">
            <.link navigate={~p"/changelog"}>Changelog</.link>
            <.link navigate={~p"/status"}>Status</.link>
            <.link navigate={~p"/leaderboard"}>Leaderboard</.link>
          </:column>
          <:column title="API">
            <.link navigate={~p"/docs/rest-api"}>REST API</.link>
            <.link navigate={~p"/docs/status-api"}>Status API</.link>
          </:column>
        </Landing.landing_footer>
      </div>
    </Layouts.app>
    """
  end
end
