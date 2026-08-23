defmodule OpenAgentsWeb.PullRequestShowLive do
  @moduledoc "Shows one repository pull request."
  use OpenAgentsWeb, :live_view

  alias OpenAgents.PullRequests
  alias OpenAgents.Repositories

  def mount(%{"owner" => owner, "repo" => repo, "number" => number}, _session, socket) do
    repository = visible_repository!(owner, repo, socket.assigns.current_user)
    pull_request = PullRequests.get_by_number!(repository, String.to_integer(number))

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:pull_request, pull_request)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title={@pull_request.issue.title}
      full_width
    >
      <main id="pull-request-show" class="app-shell code-shell">
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

          <article class="mx-auto w-full max-w-5xl px-4 py-8">
            <div class="flex flex-wrap items-center gap-3">
              <h1 class="text-2xl font-semibold text-foreground">{@pull_request.issue.title}</h1>
              <.badge variant={if(@pull_request.state == "open", do: :success, else: :secondary)}>
                {@pull_request.state}
              </.badge>
            </div>
            <p class="mt-3 text-sm text-muted-foreground">
              #{@pull_request.issue.number} proposes {@pull_request.head_repository.owner}/{@pull_request.head_repository.name}:{@pull_request.head_ref} into {@owner}/{@repo}:{@pull_request.base_ref}.
            </p>
            <div class="mt-8 rounded-xl border border-border bg-card p-6 whitespace-pre-wrap text-foreground">
              {@pull_request.issue.body || "No description provided."}
            </div>
          </article>
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
