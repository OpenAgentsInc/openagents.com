defmodule OpenAgentsWeb.DocsCatalog do
  @moduledoc """
  The documentation's table of contents, and the loader for its pages.

  Pages are Markdown files under `priv/docs`, embedded as one immutable
  compile-time snapshot, and rendered through `OpenAgents.Markdown`, which is
  the same safe CommonMark path the chat surface uses. Each source is an
  external compiler resource, so editing Markdown recompiles this allowlisted
  module and the Forge can deploy the complete snapshot transactionally.
  Documentation remains content that a writer can edit rather than HEEx that a
  writer cannot.

  Every page here documents something a visitor can actually reach today. A
  documentation site that describes features that do not exist is worse than
  one that is missing pages, because a reader cannot tell which half they are
  in. `route` is the surface each page describes, and `DocsCatalogTest`
  asserts every one of them resolves in the router.
  """

  @docs_dir Path.expand("../../priv/docs", __DIR__)
  @doc_files Path.wildcard(Path.join(@docs_dir, "*.md"))
  for path <- @doc_files, do: @external_resource(path)

  @pages Map.new(@doc_files, fn path ->
           {path |> Path.basename() |> Path.rootname(), File.read!(path)}
         end)

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
      title: "Repositories",
      items: [
        %{
          slug: "repositories",
          title: "Repository hosting",
          icon: "folder",
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
          slug: "delete-repository",
          title: "Delete a repository",
          icon: "trash",
          route: "/repositories"
        }
      ]
    },
    %{
      title: "CLI",
      items: [
        %{
          slug: "openagents-cli",
          title: "The OpenAgents CLI",
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
          slug: "cli-command-reference",
          title: "CLI command reference",
          icon: "square-code",
          route: "/repositories"
        },
        %{
          slug: "cli-api",
          title: "Call the API with the CLI",
          icon: "square-code",
          route: "/api/v1/repos/:owner/:repo/issues"
        }
      ]
    },
    %{
      title: "Issues",
      items: [
        %{
          slug: "issues",
          title: "Issue tracking",
          icon: "file-document",
          route: "/:owner/:repo/issues"
        },
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
        },
        %{
          slug: "do-not-build-register",
          title: "Do-not-build register",
          icon: "info",
          route: "/api/contracts/do-not-build-v1.json"
        }
      ]
    },
    %{
      title: "Pull requests",
      items: [
        %{
          slug: "pull-requests",
          title: "Proposing and merging changes",
          icon: "pull-request-open",
          route: "/:owner/:repo/pulls"
        },
        %{
          slug: "stacked-pull-requests",
          title: "Stacked pull requests",
          icon: "stack",
          route: "/:owner/:repo/pulls/:number"
        },
        %{
          slug: "stack-actions",
          title: "Rebase and restructure a stack",
          icon: "reload",
          route: "/:owner/:repo/pulls/:number"
        },
        %{
          slug: "merging-stacks",
          title: "Merging stacks",
          icon: "check-circle",
          route: "/api/v1/repos/:owner/:repo/stacks"
        }
      ]
    },
    %{
      title: "Projects",
      items: [
        %{
          slug: "projects",
          title: "Project boards",
          icon: "grid",
          route: "/:owner/:repo/projects"
        }
      ]
    },
    %{
      title: "Forum",
      items: [
        %{
          slug: "forum",
          title: "Boards, topics, and posts",
          icon: "comment",
          route: "/forum"
        },
        %{
          slug: "claim-legacy-identity",
          title: "Claim a legacy identity",
          icon: "user",
          route: "/forum/claim"
        }
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
      title: "Inference",
      items: [
        %{
          slug: "models",
          title: "Models and pricing",
          icon: "dollar-circle",
          route: "/models"
        }
      ]
    },
    %{
      title: "Transparency",
      items: [
        %{slug: "changelog", title: "Changelog", icon: "text", route: "/docs/changelog"},
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
          route: "/api/v1/repos/:owner/:repo/issues"
        },
        %{
          slug: "stacks-api",
          title: "Stacks API",
          icon: "square-code",
          route: "/api/v1/repos/:owner/:repo/stacks"
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
  def source_dir do
    Application.get_env(
      :openagents,
      :docs_source_dir,
      Application.app_dir(:openagents, "priv/docs")
    )
  end

  @doc """
  Render one page from the compiled documentation snapshot.

  Returns the rendered HTML, the headings found in it, and the Markdown source
  it came from, so a page, its table of contents, and the text the copy button
  hands over all come from one read rather than several that can disagree.
  """
  def render(slug) do
    with %{} = item <- fetch(slug),
         {:ok, markdown} <- Map.fetch(@pages, slug) do
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
