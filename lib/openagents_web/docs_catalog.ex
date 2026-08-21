defmodule OpenAgentsWeb.DocsCatalog do
  @moduledoc """
  The documentation's table of contents, and the loader for its pages.

  Pages are Markdown files under `priv/docs`, read at runtime and rendered
  through `OpenAgents.Markdown`, which is the same safe CommonMark path the
  chat surface uses. Documentation is content, not code, so it lives in files
  a writer can edit rather than in HEEx a writer cannot.

  Every page here documents something a visitor can actually reach today. A
  documentation site that describes features that do not exist is worse than
  one that is missing pages, because a reader cannot tell which half they are
  in. `route` is the surface each page describes, and `DocsCatalogTest`
  asserts every one of them resolves in the router.
  """

  @sections [
    %{
      title: "Getting started",
      items: [
        %{slug: "welcome", title: "Welcome", icon: "book", route: "/"},
        %{slug: "signing-in", title: "Signing in", icon: "user", route: "/"},
        %{slug: "api-tokens", title: "API tokens", icon: "key", route: "/settings/api-tokens"}
      ]
    },
    %{
      title: "Repositories and CLI",
      items: [
        %{
          slug: "openagents-cli",
          title: "Repositories and CLI",
          icon: "terminal",
          route: "/repositories"
        },
        %{
          slug: "install-cli",
          title: "Install the CLI",
          icon: "download",
          route: "/repositories"
        },
        %{
          slug: "create-repository",
          title: "Create a repository",
          icon: "square-plus",
          route: "/repositories/new"
        },
        %{
          slug: "import-github",
          title: "Import from GitHub",
          icon: "download",
          route: "/repositories/import/github"
        },
        %{
          slug: "clone-push-pull",
          title: "Clone, push, and pull",
          icon: "code",
          route: "/repositories"
        },
        %{
          slug: "cli-command-reference",
          title: "CLI command reference",
          icon: "square-code",
          route: "/repositories"
        }
      ]
    },
    %{
      title: "Issues",
      items: [
        %{slug: "issues", title: "Issues", icon: "file-document", route: "/:owner/:repo/issues"},
        %{
          slug: "creating-issues",
          title: "Creating issues",
          icon: "square-plus",
          route: "/:owner/:repo/issues/new"
        },
        %{slug: "labels", title: "Labels", icon: "tag", route: "/:owner/:repo/labels"},
        %{
          slug: "milestones",
          title: "Milestones",
          icon: "flag",
          route: "/:owner/:repo/milestones"
        },
        %{
          slug: "assignees",
          title: "Assignees",
          icon: "user",
          route: "/:owner/:repo/assignees"
        }
      ]
    },
    %{
      title: "Projects",
      items: [
        %{slug: "projects", title: "Projects", icon: "grid", route: "/:owner/:repo/projects"}
      ]
    },
    %{
      title: "Code",
      items: [
        %{
          slug: "browsing-code",
          title: "Browsing code",
          icon: "code",
          route: "/OpenAgentsInc/:repo"
        },
        %{
          slug: "commits",
          title: "Commits",
          icon: "cube",
          route: "/OpenAgentsInc/:repo/commit/:sha"
        }
      ]
    },
    %{
      title: "Transparency",
      items: [
        %{slug: "changelog", title: "Changelog", icon: "text", route: "/changelog"},
        %{slug: "status", title: "Status", icon: "check-circle", route: "/status"},
        %{slug: "leaderboard", title: "Leaderboard", icon: "star", route: "/leaderboard"}
      ]
    },
    %{
      title: "API",
      items: [
        %{
          slug: "rest-api",
          title: "REST API",
          icon: "square-code",
          route: "/api/v3/repos/:owner/:repo/issues"
        },
        %{slug: "status-api", title: "Status API", icon: "info", route: "/api/status"}
      ]
    }
  ]

  @doc "Sidebar sections, in reading order."
  def sections, do: @sections

  @doc "Every page, flattened."
  def items, do: Enum.flat_map(@sections, & &1.items)

  @doc "Every slug."
  def slugs, do: Enum.map(items(), & &1.slug)

  @doc "Look up one page by slug, or nil."
  def fetch(slug), do: Enum.find(items(), &(&1.slug == slug))

  @doc "The section title a page belongs to."
  def section_title(slug) do
    Enum.find_value(@sections, fn section ->
      if Enum.any?(section.items, &(&1.slug == slug)), do: section.title
    end)
  end

  @doc "Directory holding the Markdown sources."
  def source_dir, do: Application.app_dir(:openagents, "priv/docs")

  @doc """
  Read and render one page.

  Returns the rendered HTML, the headings found in it, and the Markdown source
  it came from, so a page, its table of contents, and the text the copy button
  hands over all come from one read rather than several that can disagree.
  """
  def render(slug) do
    with %{} = item <- fetch(slug),
         path = Path.join(source_dir(), "#{slug}.md"),
         {:ok, markdown} <- File.read(path) do
      toc = headings(markdown)
      # Authored prose, not a message: the source is wrapped for editing, and
      # those wraps are not line breaks the reader should see.
      html =
        markdown
        |> OpenAgents.Markdown.to_html(hardbreaks: false)
        |> anchor_headings(toc)

      {:ok, %{item: item, html: html, toc: toc, markdown: markdown}}
    else
      _ -> :error
    end
  end

  # The shared Markdown renderer emits no heading ids, and it should not start:
  # it is the path untrusted model output takes, and its output validation is a
  # security boundary rather than a formatting choice. Docs need anchors, so
  # they are added here, from the same headings/1 result that builds the table
  # of contents -- one source, so the rail cannot link to an id the body lacks.
  defp anchor_headings({:safe, html}, toc), do: {:safe, anchor_headings(html, toc)}

  defp anchor_headings(html, toc) when is_binary(html) do
    Enum.reduce(toc, html, fn %{title: title, level: level, id: id}, acc ->
      String.replace(
        acc,
        "<h#{level}>#{Phoenix.HTML.html_escape(title) |> Phoenix.HTML.safe_to_string()}</h#{level}>",
        ~s(<h#{level} id="#{id}">#{Phoenix.HTML.html_escape(title) |> Phoenix.HTML.safe_to_string()}</h#{level}>),
        global: false
      )
    end)
  end

  @doc """
  The `##` and `###` headings of a Markdown source, with anchor ids.

  Parsed from the source rather than the rendered HTML: the renderer escapes
  and rewrites, and a table of contents that disagrees with the anchors it
  links to is worse than none.
  """
  def headings(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, in_fence} ->
      cond do
        String.starts_with?(line, "```") -> {acc, not in_fence}
        in_fence -> {acc, in_fence}
        true -> {collect_heading(acc, line), in_fence}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp collect_heading(acc, "### " <> title), do: [heading(title, 3) | acc]
  defp collect_heading(acc, "## " <> title), do: [heading(title, 2) | acc]
  defp collect_heading(acc, _line), do: acc

  defp heading(title, level) do
    title = String.trim(title)
    %{title: title, level: level, id: anchor(title)}
  end

  @doc "The anchor id for a heading, matching what the renderer emits."
  def anchor(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
  end
end
