defmodule OpenAgentsWeb.CodeRepoLive do
  @moduledoc """
  The public repo home (#136): README render, the latest commits, and the
  ref list for a forge repo at `/:owner/:repo`. Gated by the repo's
  disclosure level (TRANSPARENCY-001 — the page needs :files since it
  renders the README). Same public read-only posture as the other
  projections; data comes from `OpenAgents.Forge.Browse`'s bounded plumbing.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forge
  alias OpenAgents.Forge.Browse
  alias OpenAgents.Forge.Pushes
  alias OpenAgents.PullRequests
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.LiveRefresh
  alias OpenAgentsWeb.OG
  alias OpenAgentsWeb.RepositoryAccess

  @impl true
  def mount(%{"owner" => owner, "repo" => name}, _session, socket) do
    repository = RepositoryAccess.get_visible!(owner, name, socket.assigns.current_user)
    base = RepositoryAccess.base(repository)
    source? = RepositoryAccess.full_source?(repository, socket.assigns.current_user)

    unless Forge.enabled?() and (source? or repository.lifecycle_state != "ready") do
      raise OpenAgentsWeb.PublicNotFoundError
    end

    delete_allowed? =
      Repositories.membership_role(repository, socket.assigns.current_user) == "owner"

    # A repository that is still provisioning is the one state this page cannot
    # render usefully, and it is also the one state that ends on its own. The
    # provisioner and the importer announce each transition, so the page hears
    # them instead of telling the reader to keep pressing refresh.
    #
    # A ready repository used to subscribe to nothing at all, which made the
    # common case the static one: a push landed and the commit list, the ref
    # counts, and the README stayed as they were, and an issue opened anywhere
    # left the tab count behind. It hears both now.
    if connected?(socket) do
      if repository.lifecycle_state != "ready" do
        :ok = Repositories.subscribe_provisioning(repository.id)
      end

      :ok = Pushes.subscribe()
      :ok = Repositories.subscribe_issues(repository.id)
    end

    {:ok,
     socket
     |> LiveRefresh.init()
     |> assign(:page_title, "#{repository.name} · code")
     |> assign(:repository, repository)
     |> assign(:repository_import, repository.repository_import)
     |> assign(:repo, repository.name)
     |> assign(:owner, repository.namespace.slug)
     |> assign(:base, base)
     |> assign(:og, OG.meta(OG.repo_card_for(repository)))
     |> assign(:clone_url, RepositoryAccess.clone_url(repository))
     |> assign(:delete_allowed?, delete_allowed?)
     |> assign(
       :pull_request_settings_form,
       pull_request_settings_form(repository.pull_requests_enabled)
     )
     |> assign(:delete_error, nil)
     |> assign(
       :delete_form,
       to_form(%{"confirmation" => ""}, as: :repository_delete)
     )
     |> refresh_panel(:source)
     |> refresh_panel(:counts)}
  rescue
    Ecto.NoResultsError -> raise OpenAgentsWeb.PublicNotFoundError
  end

  @impl true
  def handle_info({:repository_provisioning, repository_id}, socket) do
    case Repositories.get_visible_repository(repository_id, socket.assigns.current_user) do
      nil ->
        {:noreply, socket}

      %{lifecycle_state: "ready"} ->
        # Ready means there is now a head, a README, commits, and refs to read.
        # Remounting the route loads them the one way this page knows how.
        {:noreply, push_navigate(socket, to: socket.assigns.base)}

      repository ->
        {:noreply,
         socket
         |> assign(:repository, repository)
         |> assign(:repository_import, repository.repository_import)}
    end
  end

  # One accepted push, matched by storage key. The message describes the push;
  # this page describes the repository, so it re-reads rather than rendering
  # what it was handed.
  def handle_info({:forge_push, %{repo: storage_key}}, socket) do
    if storage_key == socket.assigns.repository.storage_key,
      do: {:noreply, LiveRefresh.mark_stale(socket, :source, &refresh_panel/2)},
      else: {:noreply, socket}
  end

  def handle_info({:issues_changed, repository_id}, socket) do
    if repository_id == socket.assigns.repository.id,
      do: {:noreply, LiveRefresh.mark_stale(socket, :counts, &refresh_panel/2)},
      else: {:noreply, socket}
  end

  def handle_info(:live_refresh, socket),
    do: {:noreply, LiveRefresh.run(socket, &refresh_panel/2)}

  # The Git read and the database read are separate panels, so an issue opened
  # in another tab moves the tab count without walking the object store, and a
  # push does not re-count the issues.
  defp refresh_panel(socket, :source) do
    overview = Browse.overview(socket.assigns.repository, 20)

    socket
    |> assign(:head, overview.head)
    |> assign(:readme, overview.readme)
    |> assign(:commits, overview.commits)
    |> assign(:latest, List.first(overview.commits))
    |> assign(:refs, overview.refs)
    |> assign(:entries, overview.entries)
    |> assign(:branch_count, Enum.count(overview.refs, &(&1.kind == :branch)))
    |> assign(:tag_count, Enum.count(overview.refs, &(&1.kind == :tag)))
  end

  defp refresh_panel(socket, :counts) do
    socket
    |> assign(:open_issue_count, open_issue_count(socket.assigns.repository))
    |> assign(:open_pull_request_count, open_pull_request_count(socket.assigns.repository))
  end

  @impl true
  def handle_event(
        "delete_repository",
        %{"repository_delete" => %{"confirmation" => confirmation} = params},
        socket
      ) do
    expected = "#{socket.assigns.owner}/#{socket.assigns.repo}"

    if confirmation == expected do
      case Repositories.delete_owned_repository(
             socket.assigns.owner,
             socket.assigns.repo,
             socket.assigns.current_user,
             surface: "web"
           ) do
        {:ok, _repository} ->
          {:noreply,
           socket
           |> put_flash(:info, "Repository deleted.")
           |> push_navigate(to: ~p"/repositories")}

        {:error, :repository_busy} ->
          {:noreply,
           assign(
             socket,
             :delete_error,
             "Repository provisioning is still running. Try again after it finishes."
           )}

        {:error, _reason} ->
          {:noreply,
           assign(socket, :delete_error, "OpenAgents could not delete this repository.")}
      end
    else
      {:noreply,
       socket
       |> assign(:delete_form, to_form(params, as: :repository_delete))
       |> assign(:delete_error, "Type #{expected} exactly to confirm deletion.")}
    end
  end

  def handle_event(
        "update_pull_request_setting",
        %{"repository" => %{"pull_requests_enabled" => enabled}},
        socket
      ) do
    enabled = enabled == "true"

    case Repositories.update_pull_request_setting(
           socket.assigns.owner,
           socket.assigns.repo,
           socket.assigns.current_user,
           enabled
         ) do
      {:ok, repository} ->
        {:noreply,
         socket
         |> assign(:repository, repository)
         |> assign(:pull_request_settings_form, pull_request_settings_form(enabled))
         |> put_flash(:info, "Pull request settings updated.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "OpenAgents could not update pull request settings.")}
    end
  end

  defp short(sha), do: String.slice(sha, 0, 12)

  # The tab carries a count only when there is something to count, the way the
  # component's own `count` attribute is defined: nil renders no badge.
  #
  # Issues and pull requests are counted apart because they are apart. Both tabs
  # read the same number while a pull request was an uncounted-out issue row,
  # which is the ambiguity #120 removed.
  defp open_issue_count(repository) do
    case OpenAgents.Issues.count_issues(repository, state: "open") do
      0 -> nil
      count -> count
    end
  rescue
    # The tab is decoration over another context's data. A repository whose
    # issues cannot be read is still a repository whose code should render.
    _error -> nil
  end

  defp open_pull_request_count(repository) do
    case PullRequests.count_open(repository) do
      0 -> nil
      count -> count
    end
  rescue
    _error -> nil
  end

  defp initial(name) when is_binary(name) do
    name |> String.trim() |> String.first() |> Kernel.||("?") |> String.upcase()
  end

  defp initial(_name), do: "?"

  defp pull_request_settings_form(enabled) do
    to_form(%{"pull_requests_enabled" => enabled}, as: :repository)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Code"
      full_width
    >
      <main id="code-repo-page" class="app-shell code-shell">
        <.repo_view
          owner={@owner}
          repo={@repo}
          visibility={if @repository.visibility == "public", do: :public, else: :private}
        >
          <:tabs>
            <.repo_tabs>
              <:tab icon="code" navigate={@base} current>Code</:tab>
              <:tab
                icon="octicon-issue-opened"
                navigate={"#{@base}/issues"}
                count={@open_issue_count}
              >
                Issues
              </:tab>
              <:tab
                icon="pull-request-open"
                navigate={"#{@base}/pulls"}
                count={@open_pull_request_count}
              >
                Pull requests
              </:tab>
              <:tab icon="cube" navigate={"#{@base}/projects"}>Projects</:tab>
            </.repo_tabs>
          </:tabs>

          <.alert
            :if={@repository.lifecycle_state == "provisioning"}
            id="repo-provisioning"
            variant={:info}
            title="Repository provisioning is in progress"
          >
            This page updates itself when the repository becomes ready for Git operations.
          </.alert>

          <.alert
            :if={@repository.lifecycle_state == "failed"}
            id="repo-provisioning-failed"
            variant={:danger}
            title="Repository provisioning failed"
          >
            Error code: <code>{@repository.provision_error_code || "provisioning_failed"}</code>
          </.alert>

          <.empty
            :if={@repository.lifecycle_state == "ready" and is_nil(@head)}
            id="repo-empty"
            title="This repository is empty"
          >
            Push the first commit to <code>{@repository.default_branch}</code>
            with the clone URL below.
          </.empty>

          <%!-- Only while the repository has nothing in it. Once there is a
          tree, the ref bar carries a Clone control and a second copy of the
          same command underneath it is noise -- but an empty repository has no
          ref bar, and telling someone how to push the first commit is the only
          thing this page can usefully do for them. --%>
          <.card :if={@repository.lifecycle_state == "ready" and is_nil(@head)} id="repo-clone">
            <h2>Clone</h2>
            <code class="block break-all">git clone {@clone_url}</code>
          </.card>

          <%!-- Counts rather than a list: the ref bar states how many branches
          and tags there are, and each name is reachable from there. `commits`
          is left unset because the total is not a bounded query -- an invented
          number beside two real ones is worse than one missing number. --%>
          <.file_table
            :if={@head}
            owner={@owner}
            repo={@repo}
            ref={@repository.default_branch}
            entries={@entries}
            branches={@branch_count}
            tags={@tag_count}
          >
            <:actions>
              <.copy_button
                id="repo-clone-copy"
                text={"git clone #{@clone_url}"}
                label="Clone"
                copied_label="Copied"
              />
            </:actions>
            <:commit :if={@latest}>
              <.avatar size={:sm} fallback={initial(@latest.author)} label={@latest.author} />
              <strong>{@latest.author}</strong>
              <span>{@latest.subject}</span>
              <.text_button navigate={"#{@base}/commit/#{short(@latest.sha)}"}>
                <code>{short(@latest.sha)}</code>
              </.text_button>
              <.time_ago at={@latest.committed_at} />
            </:commit>
          </.file_table>

          <%!-- A README is an authored document, not a message: its source is
          wrapped at an editing width, so hard breaks would end every one of
          those wraps in a line break and render the file at the width of its
          source rather than the width of this column. --%>
          <.card :if={@readme} id="repo-readme">
            <h2>{@readme.name}</h2>
            <div class="markdown">
              {OpenAgents.Markdown.to_html(@readme.blob.content, hardbreaks: false)}
            </div>
          </.card>

          <%!-- The ref bar counts branches and tags; this is where their names
          and heads actually are. Without it the counts are the only trace of a
          branch that is not the default one. --%>
          <.card :if={@head} id="repo-refs">
            <h2>Refs</h2>
            <ul class="code-refs">
              <li :for={ref <- @refs}>
                <.badge variant={:dim}>{ref.kind}</.badge>
                {ref.name}
                <.text_button navigate={"#{@base}/commit/#{short(ref.sha)}"}>
                  <code>{short(ref.sha)}</code>
                </.text_button>
              </li>
            </ul>
          </.card>

          <.card :if={@head} id="repo-commits">
            <h2>Recent commits</h2>
            <ol class="code-commits">
              <li :for={commit <- @commits}>
                <.text_button navigate={"#{@base}/commit/#{short(commit.sha)}"}>
                  <code>{short(commit.sha)}</code>
                </.text_button>
                <span class="code-commit-line">{commit.subject}</span>
                <span class="code-commit-author">{commit.author}</span>
                <.time_ago at={commit.committed_at} />
              </li>
            </ol>
          </.card>

          <.card :if={@delete_allowed?} id="repository-pull-request-settings">
            <header>
              <h2>Pull requests</h2>
            </header>
            <p class="text-sm text-muted-foreground">
              Allow contributors to propose changes from another hosted repository and branch.
            </p>
            <.form
              for={@pull_request_settings_form}
              id="repository-pull-request-settings-form"
              phx-submit="update_pull_request_setting"
              class="space-y-3"
            >
              <.input
                field={@pull_request_settings_form[:pull_requests_enabled]}
                type="checkbox"
                label="Allow new pull requests"
              />
              <.button id="repository-pull-request-settings-submit" type="submit">
                Save pull request settings
              </.button>
            </.form>
          </.card>

          <.card
            :if={@delete_allowed?}
            id="repository-danger-zone"
            variant={:danger}
            class="space-y-4"
          >
            <header>
              <h2>Delete repository</h2>
            </header>
            <p class="text-sm text-muted-foreground">
              This permanently deletes the repository, its Git history, issues, projects, and
              import records. You cannot undo this action.
            </p>
            <.alert
              :if={@delete_error}
              id="repository-delete-error"
              variant={:danger}
              title="Repository was not deleted"
            >
              {@delete_error}
            </.alert>
            <.form
              for={@delete_form}
              id="repository-delete-form"
              phx-submit="delete_repository"
              class="space-y-3"
            >
              <.input
                field={@delete_form[:confirmation]}
                type="text"
                label={"Type #{@owner}/#{@repo} to confirm"}
                autocomplete="off"
                required
              />
              <.button
                id="repository-delete-submit"
                type="submit"
                variant={:destructive}
                phx-disable-with="Deleting repository…"
              >
                Delete repository
              </.button>
            </.form>
          </.card>

          <:about>
            <.repo_about description={@repository.description}>
              <%!-- The file that is actually there, under the name it actually
              has. A fixed `README.md` is a guess, and a repository whose readme
              is named anything else gets a rail link to a 404. --%>
              <:link
                :if={@readme}
                icon="book"
                navigate={"#{@base}/blob/#{@repository.default_branch}/#{@readme.name}"}
              >
                {@readme.name}
              </:link>
              <:link icon="empty-circle" navigate={"#{@base}/issues"}>Issues</:link>
              <:link icon="cube" navigate={"#{@base}/projects"}>Projects</:link>
              <:stat icon="branch">
                {@branch_count} {if @branch_count == 1, do: "branch", else: "branches"}
              </:stat>
              <:stat :if={@tag_count > 0} icon="tag">
                {@tag_count} {if @tag_count == 1, do: "tag", else: "tags"}
              </:stat>
            </.repo_about>

            <%!-- REPOSITORY-001: an import freezes one authorized ref map and
            schedules no later synchronization. Keep that provenance beside
            the repository metadata instead of interrupting the code tree. --%>
            <section
              :if={@repository_import}
              id="repo-import-provenance"
              class="repo-import-provenance"
              aria-labelledby="repo-import-provenance-title"
            >
              <h2 id="repo-import-provenance-title">Imported from GitHub</h2>
              <dl>
                <div>
                  <dt>Source</dt>
                  <dd><code>{@repository_import.source_full_name}</code></dd>
                </div>
                <div :if={@repository_import.source_head_sha}>
                  <dt>Snapshot</dt>
                  <dd><code>{short(@repository_import.source_head_sha)}</code></dd>
                </div>
                <div>
                  <dt>State</dt>
                  <dd>{@repository_import.state}</dd>
                </div>
                <div :if={@repository_import.completed_at}>
                  <dt>Completed</dt>
                  <dd>
                    <time datetime={DateTime.to_iso8601(@repository_import.completed_at)}>
                      {Calendar.strftime(@repository_import.completed_at, "%Y-%m-%d %H:%M UTC")}
                    </time>
                  </dd>
                </div>
                <div :if={@repository_import.error_code}>
                  <dt>Error code</dt>
                  <dd><code>{@repository_import.error_code}</code></dd>
                </div>
              </dl>
              <p>
                OpenAgents copied this snapshot once. Later GitHub commits do not appear here.
              </p>
            </section>
          </:about>
        </.repo_view>
      </main>
    </Layouts.app>
    """
  end
end
