defmodule OpenAgentsWeb.CodeRepoLive do
  @moduledoc """
  The public repo home (#136): README render, the latest commits, and the
  ref list for a forge repo at `/:owner/:repo`. Gated by the repo's
  disclosure level (TRANSPARENCY-001 — the page needs :files since it
  renders the README). Same public read-only posture as the other
  projections; data comes from `OpenAgents.Forge.Browse`'s bounded plumbing.
  """

  use OpenAgentsWeb, :openagents_live_view

  alias OpenAgents.Forge
  alias OpenAgents.Forge.{Browse, Visibility}

  @impl true
  def mount(%{"repo" => repo}, _session, socket) do
    base = Visibility.repo_path(repo)

    unless Visibility.allows?(repo, :files) and Forge.enabled?() and base do
      raise OpenAgentsWeb.PublicNotFoundError
    end

    head =
      case Browse.head(repo) do
        {:ok, sha} -> sha
        _ -> raise OpenAgentsWeb.PublicNotFoundError
      end

    readme =
      case Browse.readme(repo, head) do
        {:ok, name, blob} -> %{name: name, blob: blob}
        _ -> nil
      end

    commits =
      case Browse.log(repo, head, 20) do
        {:ok, commits} -> commits
        _ -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "#{repo} · code")
     |> assign(:repo, repo)
     |> assign(:owner, Visibility.owner(repo))
     |> assign(:base, base)
     |> assign(:head, head)
     |> assign(:readme, readme)
     |> assign(:commits, commits)
     |> assign(:refs, Browse.refs(repo))}
  end

  defp short(sha), do: String.slice(sha, 0, 12)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="code-repo-page" class="app-shell code-shell">
        <Layouts.command_bar aria_label="OpenAgents code" current_user={@current_user}>
          <:lockup>
            <.button
              :if={@current_user}
              id="return-to-conversation"
              variant={:chip}
              size={:xs}
              phx-click={JS.navigate(~p"/chat")}
            >
              <.icon name="arrow-left" /> RETURN TO CONVERSATION
            </.button>
          </:lockup>
        </Layouts.command_bar>

        <section class="code" aria-label="Repository">
          <header class="code-heading">
            <div>
              <h1>{@owner}/{@repo}</h1>
              <p class="code-meta">
                head <code>{short(@head)}</code>
                · <.text_button navigate="/changelog">changelog</.text_button>
                · read-only mirror for anonymous clones: <code>github.com/OpenAgentsInc/{@repo}</code>
              </p>
            </div>
          </header>

          <.card id="repo-commits">
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

          <.card id="repo-refs">
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

          <.card :if={@readme} id="repo-readme">
            <h2>{@readme.name}</h2>
            <div class="code-markdown">
              {OpenAgents.Markdown.to_html(@readme.blob.content)}
            </div>
          </.card>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
