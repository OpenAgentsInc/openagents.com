defmodule OpenAgentsWeb.PullRequestIndexLive do
  @moduledoc "Lists pull requests for a repository."
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.PullRequests
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.LiveRefresh
  alias OpenAgentsWeb.UI.Circle

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    repository = visible_repository!(owner, repo, socket.assigns.current_user)
    pull_requests = PullRequests.list(repository)

    # Both tab counts hang off issue rows -- a pull request is an issue with a
    # `pull_requests` record pointing at it -- so the issue topic is the one
    # that says either of them moved.
    if connected?(socket), do: Repositories.subscribe_issues(repository.id)

    {:ok,
     socket
     |> LiveRefresh.init()
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:open_issue_count, open_issue_count(repository))
     |> assign(:open_pull_request_count, open_pull_request_count(repository))
     |> assign(:pull_requests_empty?, pull_requests == [])
     |> stream(:pull_requests, pull_requests)}
  end

  def handle_info({:issues_changed, repository_id}, socket) do
    if repository_id == socket.assigns.repository.id,
      do: {:noreply, LiveRefresh.mark_stale(socket, :pull_requests, &refresh_panel/2)},
      else: {:noreply, socket}
  end

  def handle_info(:live_refresh, socket),
    do: {:noreply, LiveRefresh.run(socket, &refresh_panel/2)}

  # The counts stay aggregates, and the list stays one read of the pull
  # requests rather than a count of them.
  defp refresh_panel(socket, :pull_requests) do
    repository = socket.assigns.repository
    pull_requests = PullRequests.list(repository)

    socket
    |> assign(:open_issue_count, open_issue_count(repository))
    |> assign(:open_pull_request_count, open_pull_request_count(repository))
    |> assign(:pull_requests_empty?, pull_requests == [])
    |> stream(:pull_requests, pull_requests, reset: true)
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
              <:tab
                icon="octicon-issue-opened"
                navigate={~p"/#{@owner}/#{@repo}/issues"}
                count={@open_issue_count}
              >
                Issues
              </:tab>
              <:tab
                icon="pull-request-open"
                navigate={~p"/#{@owner}/#{@repo}/pulls"}
                count={@open_pull_request_count}
                current
              >
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
                  <div class="flex items-start gap-2">
                    <Circle.pull_request_state state={state_label(pull_request)} class="mt-1" />
                    <div>
                      <h2 class="font-semibold text-foreground">{pull_request.issue.title}</h2>
                      <p class="mt-1 text-sm text-muted-foreground">
                        #{pull_request.issue.number} from {pull_request.head_repository.owner}/{pull_request.head_repository.name}:{pull_request.head_ref} into {pull_request.base_ref}
                      </p>
                    </div>
                  </div>
                  <.badge variant={state_variant(state_label(pull_request))}>
                    {state_label(pull_request)}
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

  defp state_label(pull_request), do: PullRequests.state(pull_request)

  # The two numbers the repository nav has to keep apart. Both were the same
  # number while pull requests were counted as issues (#120).
  defp open_issue_count(repository) do
    case Issues.count_issues(repository, state: "open") do
      0 -> nil
      count -> count
    end
  end

  defp open_pull_request_count(repository) do
    case PullRequests.count_open(repository) do
      0 -> nil
      count -> count
    end
  end

  defp state_variant("merged"), do: :done
  defp state_variant("open"), do: :success
  defp state_variant("draft"), do: :dim
  defp state_variant(_closed), do: :danger

  defp visible_repository!(owner, repo, user) do
    Repositories.get_visible_by_path!(owner, repo, user)
  rescue
    Ecto.NoResultsError ->
      raise OpenAgentsWeb.PublicNotFoundError, message: "repository not found"
  end
end
