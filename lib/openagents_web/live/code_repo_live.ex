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
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.RepositoryAccess

  @impl true
  def mount(%{"owner" => owner, "repo" => name}, _session, socket) do
    repository = RepositoryAccess.get_visible!(owner, name, socket.assigns.current_user)
    base = RepositoryAccess.base(repository)
    source? = RepositoryAccess.full_source?(repository, socket.assigns.current_user)

    unless Forge.enabled?() and (source? or repository.lifecycle_state != "ready") do
      raise OpenAgentsWeb.PublicNotFoundError
    end

    head =
      case Browse.head(repository) do
        {:ok, sha} -> sha
        _ -> nil
      end

    readme =
      case head && Browse.readme(repository, head) do
        {:ok, name, blob} -> %{name: name, blob: blob}
        _ -> nil
      end

    commits =
      case head && Browse.log(repository, head, 20) do
        {:ok, commits} -> commits
        _ -> []
      end

    entries =
      case head && Browse.tree(repository, head) do
        {:ok, entries} -> entries
        _ -> []
      end

    refs = if head, do: Browse.refs(repository), else: []

    # A repository that is still provisioning is the one state this page cannot
    # render usefully, and it is also the one state that ends on its own. The
    # provisioner and the importer announce each transition, so the page hears
    # them instead of telling the reader to keep pressing refresh.
    if connected?(socket) and repository.lifecycle_state != "ready" do
      :ok = Repositories.subscribe_provisioning(repository.id)
    end

    {:ok,
     socket
     |> assign(:page_title, "#{repository.name} · code")
     |> assign(:repository, repository)
     |> assign(:repository_import, repository.repository_import)
     |> assign(:repo, repository.name)
     |> assign(:owner, repository.namespace.slug)
     |> assign(:base, base)
     |> assign(:head, head)
     |> assign(:readme, readme)
     |> assign(:commits, commits)
     |> assign(:latest, List.first(commits))
     |> assign(:refs, refs)
     |> assign(:entries, entries)
     |> assign(:branch_count, Enum.count(refs, &(&1.kind == :branch)))
     |> assign(:tag_count, Enum.count(refs, &(&1.kind == :tag)))
     |> assign(:open_issue_count, open_issue_count(repository))
     |> assign(:clone_url, RepositoryAccess.clone_url(repository))}
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

  defp short(sha), do: String.slice(sha, 0, 12)

  # The tab carries a count only when there is something to count, the way the
  # component's own `count` attribute is defined: nil renders no badge.
  defp open_issue_count(repository) do
    case OpenAgents.Issues.list_issues(repository, state: "open") do
      [] -> nil
      issues -> length(issues)
    end
  rescue
    # The tab is decoration over another context's data. A repository whose
    # issues cannot be read is still a repository whose code should render.
    _error -> nil
  end

  # `%cI` from `Browse.log/3`, which is strict ISO 8601.
  defp committed_at(%{committed_at: stamp}) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _offset} -> at
      _unparseable -> nil
    end
  end

  defp committed_at(_commit), do: nil

  defp initial(name) when is_binary(name) do
    name |> String.trim() |> String.first() |> Kernel.||("?") |> String.upcase()
  end

  defp initial(_name), do: "?"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Code"
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
              <:tab icon="empty-circle" navigate={"#{@base}/issues"} count={@open_issue_count}>
                Issues
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

          <%!-- REPOSITORY-001: an import freezes one authorized ref map and
          schedules no later synchronization, so this states the source, what
          was accepted, and that nothing keeps the two in step. Never labelled
          synced or mirrored. --%>
          <.card :if={@repository_import} id="repo-import-provenance">
            <h2>Imported once from GitHub</h2>
            <dl class="grid gap-x-4 gap-y-1 text-sm sm:grid-cols-[auto_1fr]">
              <dt class="text-muted-foreground">Source</dt>
              <dd><code>{@repository_import.source_full_name}</code></dd>

              <dt :if={@repository_import.source_head_sha} class="text-muted-foreground">
                Accepted snapshot
              </dt>
              <dd :if={@repository_import.source_head_sha}>
                <code>{short(@repository_import.source_head_sha)}</code>
              </dd>

              <dt class="text-muted-foreground">State</dt>
              <dd>{@repository_import.state}</dd>

              <dt :if={@repository_import.completed_at} class="text-muted-foreground">Completed</dt>
              <dd :if={@repository_import.completed_at}>
                <time datetime={DateTime.to_iso8601(@repository_import.completed_at)}>
                  {Calendar.strftime(@repository_import.completed_at, "%Y-%m-%d %H:%M UTC")}
                </time>
              </dd>

              <dt :if={@repository_import.error_code} class="text-muted-foreground">Error code</dt>
              <dd :if={@repository_import.error_code}>
                <code>{@repository_import.error_code}</code>
              </dd>
            </dl>
            <p class="mt-3 text-sm text-muted-foreground">
              OpenAgents copied this snapshot once and is now the source of truth for it.
              Later commits on GitHub do not appear here.
            </p>
          </.card>

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
              <time :if={committed_at(@latest)} datetime={@latest.committed_at}>
                {Calendar.strftime(committed_at(@latest), "%Y-%m-%d")}
              </time>
            </:commit>
          </.file_table>

          <.card :if={@readme} id="repo-readme">
            <h2>{@readme.name}</h2>
            <div class="code-markdown">
              {OpenAgents.Markdown.to_html(@readme.blob.content)}
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
              </li>
            </ol>
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
          </:about>
        </.repo_view>
      </main>
    </Layouts.app>
    """
  end
end
