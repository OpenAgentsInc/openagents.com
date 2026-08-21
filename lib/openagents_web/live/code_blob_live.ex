defmodule OpenAgentsWeb.CodeBlobLive do
  @moduledoc """
  The public file view (#136): a stable, shareable openagents.com URL for
  any file at any ref on a forge repo —
  `/:owner/:repo/blob/:ref/*path`. Branch URLs are living (they follow the
  branch); sha-pinned URLs are permanent.

  Served straight from the bare repo through `OpenAgents.Forge.Browse` (bounded
  git plumbing, WAL-fresh), gated by the repo's disclosure level
  (`OpenAgents.Forge.Visibility`, TRANSPARENCY-001 — files need :l3). Markdown
  renders through `OpenAgents.Markdown`'s bounded MDEx sanitizer; everything else is an
  escaped code block; binaries are named, never rendered. Public posture as
  the leaderboard: read-only, no session required, cannot invoke OpenAgents.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forge.Browse
  alias OpenAgentsWeb.OG
  alias OpenAgentsWeb.RepositoryAccess

  @impl true
  def mount(%{"owner" => owner, "repo" => name, "ref" => ref} = params, _session, socket) do
    path = params |> Map.get("path", []) |> Enum.join("/")
    repository = RepositoryAccess.get_visible!(owner, name, socket.assigns.current_user)
    base = RepositoryAccess.base(repository)

    unless OpenAgents.Forge.enabled?() and repository.lifecycle_state == "ready" do
      raise OpenAgentsWeb.PublicNotFoundError
    end

    sha =
      case Browse.resolve_commit(repository, ref) do
        {:ok, sha} -> sha
        _ -> raise OpenAgentsWeb.PublicNotFoundError
      end

    # Either the whole repo is browsable (:l3), or this is a published
    # document at the current head. A published path at an older ref is a
    # 404: publishing one document must not publish its history.
    head = with {:ok, head} <- Browse.head(repository), do: head

    unless RepositoryAccess.allows_file?(
             repository,
             socket.assigns.current_user,
             path,
             sha,
             head
           ) do
      raise OpenAgentsWeb.PublicNotFoundError
    end

    blob =
      case Browse.blob(repository, sha, path) do
        {:ok, blob} -> blob
        _ -> raise OpenAgentsWeb.PublicNotFoundError
      end

    plain = Map.get(params, "plain") == "1"

    {:ok,
     socket
     |> assign(:page_title, "#{Path.basename(path)} · #{repository.name}")
     |> assign(:repository, repository)
     |> assign(:repo, repository.name)
     |> assign(:owner, repository.namespace.slug)
     |> assign(:base, base)
     |> assign(:ref, ref)
     |> assign(:sha, sha)
     |> assign(:path, path)
     |> assign(:blob, blob)
     |> assign(
       :og,
       OG.meta(
         OG.blob(repository.namespace.slug, repository.name, path, %{
           ref: ref,
           size: blob.size,
           lines: if(blob.binary, do: nil, else: blob.content |> String.split("\n") |> length()),
           truncated: blob.truncated
         })
       )
     )
     |> assign(:browsable, RepositoryAccess.full_source?(repository, socket.assigns.current_user))
     |> assign(:markdown?, markdown?(path) and not plain and not blob.binary)}
  rescue
    Ecto.NoResultsError -> raise OpenAgentsWeb.PublicNotFoundError
  end

  defp markdown?(path), do: String.ends_with?(String.downcase(path), [".md", ".markdown"])

  defp short(sha), do: String.slice(sha, 0, 12)

  defp size_text(nil), do: "—"
  defp size_text(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp size_text(bytes) when bytes < 1_048_576, do: "#{div(bytes, 1_024)} KB"
  defp size_text(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={assigns[:current_scope]}
      title="Code"
    >
      <main id="code-blob-page" class="app-shell code-shell">
        <section class="code" aria-label="File view">
          <header class="code-heading">
            <div>
              <h1 class="code-path">{@path}</h1>
              <p class="code-meta">
                <code>{@ref}</code>
                <span :if={@ref != short(@sha)}>
                  at
                  <.text_button navigate={"#{@base}/commit/#{short(@sha)}"}>
                    <code>{short(@sha)}</code>
                  </.text_button>
                </span>
                · {size_text(@blob.size)}
                <span :if={@blob.truncated}>· truncated for display</span>
              </p>
            </div>
            <div class="code-actions">
              <.button
                :if={markdown?(@path) and not @blob.binary}
                id="code-plain-toggle"
                variant={:chip}
                size={:xs}
                phx-click={
                  JS.navigate(
                    "#{@base}/blob/#{@ref}/#{@path}" <>
                      if(@markdown?, do: "?plain=1", else: "")
                  )
                }
              >
                {if @markdown?, do: "VIEW SOURCE", else: "VIEW RENDERED"}
              </.button>
            </div>
          </header>

          <.alert :if={@blob.truncated} id="code-truncated" variant={:warning}>
            This file is larger than the display bound; the tail is cut. The
            full file is in the repository itself.
          </.alert>

          <.card id="code-blob">
            <%!-- Authored document, not a message: hard breaks belong to
            typed text, and here they would only reproduce the source file's
            own wrapping. --%>
            <div :if={@markdown?} class="markdown">
              {OpenAgents.Markdown.to_html(@blob.content, hardbreaks: false)}
            </div>
            <pre :if={not @markdown? and not @blob.binary} class="code-source"><code>{@blob.content}</code></pre>
            <.empty :if={@blob.binary} id="code-binary" title="Binary file">
              {size_text(@blob.size)} of binary content — not rendered.
            </.empty>
          </.card>

          <footer class="code-footer">
            <p :if={@browsable}>
              A branch URL follows the branch; this exact revision is
              permanent at
              <.text_button navigate={"#{@base}/blob/#{short(@sha)}/#{@path}"}>
                {@base}/blob/{short(@sha)}/{@path}
              </.text_button>
            </p>
            <p :if={!@browsable}>
              A published document from a private repository. It is served at
              the current revision only — earlier revisions are not public —
              and the rest of the source is not browsable. See
              <.text_button navigate="/changelog">the changelog</.text_button>
              for what has changed and when.
            </p>
          </footer>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
