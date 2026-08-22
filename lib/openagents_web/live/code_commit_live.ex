defmodule OpenAgentsWeb.CodeCommitLive do
  @moduledoc """
  The public commit view (#137): message, provenance trailers, changed
  files, the diff — and the commit's **deploy story**, the receipt chain
  joined from `OpenAgents.Forge.receipts_for/2`: pushed (role, WAL seq),
  promoted, built (modules), and deployed (result, canary, measured
  push→live). A sha with no receipts says so honestly.

  Disclosure per TRANSPARENCY-001: the page needs :ledger; the diff body
  additionally needs :diffs. Live over the forge PubSub, so a promote made
  while the page is open completes its story in place. Public posture as
  the other projections: read-only, sessionless, cannot invoke OpenAgents.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forge
  alias OpenAgents.Forge.Browse
  alias OpenAgentsWeb.OG
  alias OpenAgentsWeb.RepositoryAccess

  @impl true
  def mount(%{"owner" => owner, "repo" => name, "sha" => sha}, _session, socket) do
    repository = RepositoryAccess.get_visible!(owner, name, socket.assigns.current_user)
    base = RepositoryAccess.base(repository)

    unless RepositoryAccess.ledger?(repository, socket.assigns.current_user) and Forge.enabled?() do
      raise OpenAgentsWeb.PublicNotFoundError
    end

    commit =
      case Browse.commit(repository, sha) do
        {:ok, commit} -> commit
        _ -> raise OpenAgentsWeb.PublicNotFoundError
      end

    files =
      case Browse.changed_files(repository, commit.sha) do
        {:ok, files} -> files
        _ -> []
      end

    {diff, diff_truncated} =
      if RepositoryAccess.full_source?(repository, socket.assigns.current_user) do
        case Browse.diff(repository, commit.sha) do
          {:ok, diff, truncated} -> {diff, truncated}
          _ -> {nil, false}
        end
      else
        {nil, false}
      end

    diff_files = OpenAgents.Diff.parse(diff)

    if connected?(socket) do
      Enum.each(
        ["forge:target", "forge:deploys"],
        &Phoenix.PubSub.subscribe(OpenAgents.PubSub, &1)
      )
    end

    {:ok,
     socket
     |> assign(:page_title, "#{short(commit.sha)} · #{repository.name}")
     |> assign(:repository, repository)
     |> assign(:repo, repository.storage_key)
     |> assign(:name, repository.name)
     |> assign(:owner, repository.namespace.slug)
     |> assign(:base, base)
     |> assign(:commit, commit)
     |> assign(:files, files)
     |> assign(
       :og,
       OG.meta(
         OG.commit(repository.namespace.slug, repository.name, commit, files && length(files))
       )
     )
     |> assign(:diff, diff)
     |> assign(:diff_truncated, diff_truncated)
     |> assign(:diff_files, diff_files)
     |> assign(:diff_totals, OpenAgents.Diff.totals(diff_files))
     |> assign(:receipts, Forge.receipts_for(repository.storage_key, commit.sha))}
  rescue
    Ecto.NoResultsError -> raise OpenAgentsWeb.PublicNotFoundError
  end

  @impl true
  def handle_info({event, %{sha: sha}}, socket)
      when event in [:forge_target, :forge_target_status, :forge_deploy] do
    if Forge.sha_match?(sha, socket.assigns.commit.sha) do
      {:noreply,
       assign(
         socket,
         :receipts,
         Forge.receipts_for(socket.assigns.repo, socket.assigns.commit.sha)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp short(sha), do: String.slice(sha, 0, 12)

  # Only the role prefix of a push principal is ever published.
  defp role_of(principal), do: principal |> to_string() |> String.split(":", parts: 2) |> hd()

  defp ms_text(nil), do: "—"
  defp ms_text(ms) when ms < 1_000, do: "#{ms} ms"
  defp ms_text(ms), do: "#{Float.round(ms / 1_000, 1)} s"

  defp module_text(1), do: "1 module"
  defp module_text(count), do: "#{count} modules"

  defp result_variant("live"), do: :success
  defp result_variant("reverted"), do: :danger
  defp result_variant("failed"), do: :danger
  defp result_variant(_), do: :warning

  defp status_variant("live"), do: :success
  defp status_variant(status) when status in ["failed", "reverted"], do: :danger
  defp status_variant("needs_rolling_replace"), do: :warning
  defp status_variant(_), do: :info

  defp trailer_link?({"Claude-Session", value}), do: String.starts_with?(value, "https://")
  defp trailer_link?(_), do: false

  defp file_status("A"), do: "added"
  defp file_status("M"), do: "modified"
  defp file_status("D"), do: "deleted"
  defp file_status("R" <> _), do: "renamed"
  defp file_status(other), do: other

  defp no_receipts?(receipts) do
    receipts.pushes == [] and receipts.targets == [] and receipts.deploys == [] and
      receipts.builds == []
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Commit"
      full_width
    >
      <main id="code-commit-page" class="app-shell code-shell">
        <section class="code" aria-label="Commit view">
          <header class="code-heading">
            <div>
              <h1 class="code-commit-subject">{@commit.subject}</h1>
              <p class="code-meta">
                <code>{short(@commit.sha)}</code>
                · {@commit.author} · {@commit.committed_at}
                <span :for={parent <- @commit.parents}>
                  · parent
                  <.text_button navigate={"#{@base}/commit/#{short(parent)}"}>
                    <code>{short(parent)}</code>
                  </.text_button>
                </span>
              </p>
            </div>
          </header>

          <.card id="commit-message">
            <pre class="code-message">{@commit.message}</pre>
            <dl :if={@commit.trailers != []} class="code-trailers">
              <div :for={{key, value} <- @commit.trailers}>
                <dt>{key}</dt>
                <dd :if={trailer_link?({key, value})}>
                  <.text_button href={value}>{value}</.text_button>
                </dd>
                <dd :if={!trailer_link?({key, value})}>{value}</dd>
              </div>
            </dl>
          </.card>

          <.card id="commit-deploy-story">
            <h2>Deploy story</h2>
            <p class="code-intro">
              What this commit did to the running system — joined from the
              forge receipt chain, the part a commit page elsewhere cannot
              show.
            </p>

            <.empty
              :if={no_receipts?(@receipts)}
              id="commit-no-receipts"
              title="Not deployed through the forge lane"
            >
              No push, promotion, build, or deploy receipt references this
              commit (receipts are scanned over a bounded recent window).
              Changes shipped by full node replacement carry their proof in
              the release gate receipt instead.
            </.empty>

            <dl :if={!no_receipts?(@receipts)} class="code-receipts">
              <div :for={push <- @receipts.pushes}>
                <dt>pushed</dt>
                <dd>
                  by {role_of(push.principal)} · WAL seq {push.wal_seq} · {push.inserted_at}
                </dd>
              </div>
              <div :for={target <- @receipts.targets}>
                <dt>promoted</dt>
                <dd>
                  by {role_of(target.promoted_by)} ·
                  <.badge variant={status_variant(target.status)}>{target.status}</.badge>
                  · {target.inserted_at}
                </dd>
              </div>
              <div :for={build <- @receipts.builds}>
                <dt>built</dt>
                <dd>
                  {length(build.modules || [])} modules in {ms_text(build.duration_ms)}
                </dd>
              </div>
              <div :for={deploy <- @receipts.deploys}>
                <dt>deployed</dt>
                <dd>
                  <.badge variant={result_variant(deploy.result)}>{deploy.result}</.badge>
                  · {module_text(length(deploy.modules || []))} on {length(deploy.nodes || [])} nodes
                  · push→live {ms_text(deploy.push_to_live_ms)}
                </dd>
              </div>
            </dl>
          </.card>

          <.card id="commit-files">
            <h2>Changed files</h2>
            <.empty :if={@files == []} id="commit-no-files" title="No file changes">
              An empty or merge commit.
            </.empty>
            <ul :if={@files != []} class="code-files">
              <li :for={file <- @files}>
                <.badge variant={:dim}>{file_status(file.status)}</.badge>
                <code>{file.path}</code>
              </li>
            </ul>
          </.card>

          <.card :if={@diff} id="commit-diff">
            <h2>Diff</h2>
            <.alert :if={@diff_truncated} id="commit-diff-truncated" variant={:warning}>
              The diff is larger than the display bound; the tail is cut.
            </.alert>

            <p :if={@diff_files != []} id="commit-diff-totals" class="diff-totals">
              {@diff_totals.files} {ngettext("file", "files", @diff_totals.files)} changed,
              <span data-kind="insert">+{@diff_totals.insertions}</span>
              <span data-kind="delete">-{@diff_totals.deletions}</span>
            </p>

            <.diff_file :for={file <- @diff_files} file={file} />

            <%!-- The parser returns [] for input it cannot read. Showing the
            raw text then is better than showing nothing: the diff is a report
            about a repository, and a shape this code has not seen should still
            reach the reader. --%>
            <pre :if={@diff_files == []} class="code-source code-diff"><code>{@diff}</code></pre>
          </.card>

          <footer class="code-footer">
            <p>
              This page updates live while a promote is in flight ·
              <.text_button navigate="/changelog">changelog</.text_button>
            </p>
          </footer>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
