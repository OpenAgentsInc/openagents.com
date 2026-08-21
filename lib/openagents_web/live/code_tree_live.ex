defmodule OpenAgentsWeb.CodeTreeLive do
  @moduledoc """
  The public directory view for a repository path at a branch, tag, or commit.

  The route follows GitHub's `/:owner/:repo/tree/:ref/*path` shape. Directory
  reads use the same bounded Git plumbing and repository visibility policy as
  the repository home and file view.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forge.Browse
  alias OpenAgentsWeb.RepositoryAccess

  @impl true
  def mount(%{"owner" => owner, "repo" => name, "ref" => ref} = params, _session, socket) do
    path = params |> Map.get("path", []) |> Enum.join("/")
    repository = RepositoryAccess.get_visible!(owner, name, socket.assigns.current_user)

    unless OpenAgents.Forge.enabled?() and
             RepositoryAccess.full_source?(repository, socket.assigns.current_user) do
      raise OpenAgentsWeb.PublicNotFoundError
    end

    sha =
      case Browse.resolve_commit(repository, ref) do
        {:ok, sha} -> sha
        _ -> raise OpenAgentsWeb.PublicNotFoundError
      end

    entries =
      case Browse.tree(repository, sha, path) do
        {:ok, entries} -> entries
        _ -> raise OpenAgentsWeb.PublicNotFoundError
      end

    refs = Browse.refs(repository)
    base = RepositoryAccess.base(repository)

    {:ok,
     socket
     |> assign(:page_title, "#{display_path(path)} · #{repository.name}")
     |> assign(:repository, repository)
     |> assign(:repo, repository.name)
     |> assign(:owner, repository.namespace.slug)
     |> assign(:base, base)
     |> assign(:ref, ref)
     |> assign(:sha, sha)
     |> assign(:path, path)
     |> assign(:entries, entries)
     |> assign(:breadcrumbs, breadcrumbs(base, ref, path))
     |> assign(:branch_count, Enum.count(refs, &(&1.kind == :branch)))
     |> assign(:tag_count, Enum.count(refs, &(&1.kind == :tag)))}
  rescue
    Ecto.NoResultsError -> raise OpenAgentsWeb.PublicNotFoundError
  end

  defp display_path(""), do: "Files"
  defp display_path(path), do: path

  defp breadcrumbs(base, ref, path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map_reduce([], fn segment, parents ->
      current = parents ++ [segment]
      {%{name: segment, href: "#{base}/tree/#{ref}/#{Enum.join(current, "/")}"}, current}
    end)
    |> elem(0)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Code"
    >
      <main id="code-tree-page" class="app-shell code-shell">
        <.repo_view
          owner={@owner}
          repo={@repo}
          visibility={if @repository.visibility == "public", do: :public, else: :private}
        >
          <:tabs>
            <.repo_tabs>
              <:tab icon="code" navigate={@base} current>Code</:tab>
              <:tab icon="empty-circle" navigate={"#{@base}/issues"}>Issues</:tab>
              <:tab icon="cube" navigate={"#{@base}/projects"}>Projects</:tab>
            </.repo_tabs>
          </:tabs>

          <nav class="code-heading" aria-label="Repository path">
            <h1 class="code-path">
              <.text_button navigate={@base}>{@repo}</.text_button>
              <span :for={crumb <- @breadcrumbs}>
                / <.text_button navigate={crumb.href}>{crumb.name}</.text_button>
              </span>
            </h1>
            <p class="code-meta">
              <code>{@ref}</code> at <code>{String.slice(@sha, 0, 12)}</code>
            </p>
          </nav>

          <.file_table
            owner={@owner}
            repo={@repo}
            ref={@ref}
            path={@path}
            entries={@entries}
            branches={@branch_count}
            tags={@tag_count}
          />
        </.repo_view>
      </main>
    </Layouts.app>
    """
  end
end
