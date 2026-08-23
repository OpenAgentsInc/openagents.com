defmodule OpenAgentsWeb.PullRequestIndexLive do
  @moduledoc "Lists pull requests for a repository."
  use OpenAgentsWeb, :live_view

  alias OpenAgents.PullRequests
  alias OpenAgents.Repositories

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    repository = visible_repository!(owner, repo, socket.assigns.current_user)
    pull_requests = PullRequests.list(repository)

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:pull_requests_empty?, pull_requests == [])
     |> stream(:pull_requests, pull_requests)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Pull requests"
      full_width
    >
      <main id="pull-request-index" class="app-shell code-shell">
        <.repo_view
          owner={@owner}
          repo={@repo}
          visibility={if @repository.visibility == "public", do: :public, else: :private}
        >
          <:tabs>
            <.repo_tabs>
              <:tab icon="code" navigate={~p"/#{@owner}/#{@repo}"}>Code</:tab>
              <:tab icon="empty-circle" navigate={~p"/#{@owner}/#{@repo}/issues"}>Issues</:tab>
              <:tab icon="pull-request-open" navigate={~p"/#{@owner}/#{@repo}/pulls"} current>
                Pull requests
              </:tab>
              <:tab icon="cube" navigate={~p"/#{@owner}/#{@repo}/projects"}>Projects</:tab>
            </.repo_tabs>
          </:tabs>

          <section class="mx-auto w-full max-w-5xl px-4 py-8">
            <div id="pull-requests" phx-update="stream" class="space-y-3">
              <.empty
                :if={@pull_requests_empty?}
                id="pull-requests-empty"
                title="No pull requests"
              >
                No pull requests are open or closed in this repository.
              </.empty>
              <.link
                :for={{id, pull_request} <- @streams.pull_requests}
                id={id}
                navigate={~p"/#{@owner}/#{@repo}/pulls/#{pull_request.issue.number}"}
                class="block rounded-xl border border-border bg-card p-4 transition-colors hover:bg-muted/50"
              >
                <div class="flex items-start justify-between gap-4">
                  <div>
                    <h2 class="font-semibold text-foreground">{pull_request.issue.title}</h2>
                    <p class="mt-1 text-sm text-muted-foreground">
                      #{pull_request.issue.number} from {pull_request.head_repository.owner}/{pull_request.head_repository.name}:{pull_request.head_ref} into {pull_request.base_ref}
                    </p>
                  </div>
                  <.badge variant={if(pull_request.state == "open", do: :success, else: :secondary)}>
                    {pull_request.state}
                  </.badge>
                </div>
              </.link>
            </div>
          </section>
        </.repo_view>
      </main>
    </Layouts.app>
    """
  end

  defp visible_repository!(owner, repo, user) do
    Repositories.get_visible_by_path!(owner, repo, user)
  rescue
    Ecto.NoResultsError ->
      raise OpenAgentsWeb.PublicNotFoundError, message: "repository not found"
  end
end
