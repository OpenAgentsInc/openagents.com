defmodule OpenAgentsWeb.OG do
  @moduledoc """
  Server-generated Open Graph cards.

  A `%Card{}` is the single unit that flows through the whole pipeline: views
  build one from data they already rendered, this module turns it into a
  content-versioned signed URL for the `<meta>` tags, and
  `OpenAgentsWeb.OgImageController` rebuilds it at request time and renders it
  to PNG. See `docs/2026-08-21-open-graph-cards.md`.

  The security posture of cards matches the pages they describe: a card may
  contain only data the anonymous page already displays, every dynamic string
  is escaped and clamped before it reaches a template, and the image endpoint
  resolves repositories through the public visibility predicate.
  """

  @enforce_keys [:kind]
  defstruct [
    :kind,
    :kicker,
    :heading,
    :description,
    :avatar,
    :provenance,
    chips: [],
    stats: [],
    title: nil,
    # Canonical page URL this card describes (for og:url), e.g.
    # "/OpenAgentsInc/openagents.com/issues/12".
    page_path: nil,
    # Path segments under "/og/v/{version}/repos/", e.g.
    # ["Owner", "repo"] or ["Owner", "repo", "blob", "main", "lib/a.ex"].
    path_suffix: []
  ]

  @type kind :: :site | :repo | :issue | :blob | :commit

  @type t :: %__MODULE__{
          kind: kind(),
          kicker: String.t() | nil,
          heading: String.t() | nil,
          description: String.t() | nil,
          avatar: String.t() | nil,
          provenance: String.t() | nil,
          chips: [%{required(:label) => String.t(), optional(:tone) => atom}],
          stats: [String.t()],
          title: String.t() | nil,
          page_path: String.t() | nil,
          path_suffix: [String.t()]
        }

  @version_bytes 12
  @signature_bytes 16

  # ── builders ────────────────────────────────────────────────────────────────

  @doc "The site-level card every page falls back to."
  def site do
    %__MODULE__{
      kind: :site,
      kicker: "OPENAGENTS",
      heading: "The agent-native forge",
      description: "Host your code, track your issues, and work with agents."
    }
  end

  @doc """
  A repository card. Nil inputs simply drop their stat; a repository without
  a description says so rather than showing a blank band.
  """
  def repo(repository, opts \\ []) when is_list(opts) do
    owner = namespace_slug(repository)
    suffix = [owner, repository.name]

    %__MODULE__{
      kind: :repo,
      kicker: "#{owner} /",
      heading: repository.name,
      description: present(repository.description) || "No description yet.",
      chips: [%{label: "Public"}],
      stats:
        clean_stats([
          opt_stat(opts[:default_branch]),
          issue_stat(opts[:open_issues], opts[:closed_issues]),
          dated_stat("Updated", opts[:updated_at])
        ]),
      provenance: if(opts[:imported], do: "Imported from GitHub"),
      title: meta_title("#{owner}/#{repository.name}"),
      page_path: Path.join(["/" | suffix]),
      path_suffix: suffix
    }
  end

  @doc "An issue card: state, title, author, labels, and conversation size."
  def issue(repository_owner, repository_name, issue) do
    labels = Enum.take(issue.labels || [], 3)
    hidden = max(length(issue.labels || []) - length(labels), 0)
    number_string = Integer.to_string(issue.number)

    chips =
      [%{label: state_label(issue), tone: state_tone(issue)}] ++
        Enum.map(labels, &%{label: &1["name"]}) ++
        List.wrap(if(hidden > 0, do: %{label: "+#{hidden}"}, else: nil))

    author = author_login(issue)

    %__MODULE__{
      kind: :issue,
      kicker: "#{repository_owner}/#{repository_name} · ##{number_string}",
      heading: issue.title || "(no title)",
      avatar: author,
      chips: chips,
      stats:
        clean_stats([
          opt_stat(author),
          dated_stat("Opened", issue.inserted_at),
          comments_stat(issue.comments)
        ]),
      title: meta_title("#{issue.title || "(no title)"} · Issue ##{number_string}"),
      page_path: "/#{repository_owner}/#{repository_name}/issues/#{number_string}",
      path_suffix: [repository_owner, repository_name, "issues", number_string]
    }
  end

  @doc """
  A file card — the layer GitHub does not have. `info` accepts `:ref`,
  `:size`, `:lines`, and `:truncated`; anything missing drops its stat.
  """
  def blob(repository_owner, repository_name, path, info) when is_map(info) do
    filename = basename(path)
    language = language_for_path(path)

    %__MODULE__{
      kind: :blob,
      kicker: "#{repository_owner}/#{repository_name}",
      heading: filename,
      description: display_path(path),
      chips: chip_wrap(language),
      stats:
        clean_stats([
          opt_stat(info[:ref]),
          opt_stat(size_stat(info[:size])),
          lines_stat(info[:lines], info[:truncated])
        ]),
      title: meta_title(filename),
      page_path: "/#{repository_owner}/#{repository_name}/blob/#{info[:ref]}/#{path}",
      path_suffix: [repository_owner, repository_name, "blob", info[:ref], path]
    }
  end

  @doc "A commit card: subject, author, date, and changed-file count."
  def commit(repository_owner, repository_name, commit_info, file_count) do
    subject = present(commit_info[:subject]) || present(commit_info[:sha]) || "Commit"
    sha = commit_info[:sha]

    %__MODULE__{
      kind: :commit,
      kicker: "#{repository_owner}/#{repository_name}",
      heading: subject,
      avatar: commit_info[:author],
      chips: chip_wrap(sha && short_sha(sha)),
      stats:
        clean_stats([
          opt_stat(commit_info[:author]),
          dated_stat("Committed", commit_info[:committed_at]),
          file_count && plural(file_count, "changed file", "changed files")
        ]),
      title: meta_title(subject),
      page_path: "/#{repository_owner}/#{repository_name}/commit/#{sha}",
      path_suffix: [repository_owner, repository_name, "commit", sha]
    }
  end

  defp clean_stats(stats), do: Enum.reject(stats, &(is_nil(&1) or &1 == ""))

  defp opt_stat(value), do: present(value)

  defp issue_stat(open, closed) when is_integer(open) and is_integer(closed),
    do: "#{open} open · #{closed} closed"

  defp issue_stat(open, _) when is_integer(open), do: plural(open, "open issue", "open issues")
  defp issue_stat(_, closed) when is_integer(closed), do: plural(closed, "closed", "closed")
  defp issue_stat(_, _), do: nil

  defp comments_stat(count) when is_integer(count) and count > 0,
    do: plural(count, "comment", "comments")

  defp comments_stat(_), do: nil

  defp size_stat(bytes) when is_integer(bytes), do: format_size(bytes)
  defp size_stat(_), do: nil

  defp lines_stat(lines, true) when is_integer(lines) and lines > 0, do: ">#{lines}+ lines"

  defp lines_stat(lines, _) when is_integer(lines) and lines > 0,
    do: plural(lines, "line", "lines")

  defp lines_stat(_, _), do: nil

  defp dated_stat(prefix, %Date{} = date),
    do: "#{prefix} #{Calendar.strftime(date, "%b %-d, %Y")}"

  defp dated_stat(prefix, %DateTime{} = dt),
    do: dated_stat(prefix, DateTime.shift_zone!(dt, "Etc/UTC") |> DateTime.to_date())

  defp dated_stat(prefix, %NaiveDateTime{} = dt),
    do: dated_stat(prefix, DateTime.from_naive!(dt, "Etc/UTC"))

  defp dated_stat(prefix, text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> dated_stat(prefix, dt)
      _ -> nil
    end
  end

  defp dated_stat(_prefix, _other), do: nil

  defp chip_wrap(nil), do: []
  defp chip_wrap(label), do: [%{label: label}]

  @doc """
  Repository card assembled defensively from an already-loaded repository:
  issue counts, last-commit date, and import provenance become best-effort
  stats. A repository whose Git lane or issues cannot be read still gets a
  complete-looking card rather than no card at all.
  """
  def repo_card_for(%OpenAgents.Repositories.Repository{} = repository) do
    repo(repository,
      default_branch: repository.default_branch,
      open_issues: safe(fn -> OpenAgents.Issues.count_issues(repository, state: "open") end),
      closed_issues: safe(fn -> OpenAgents.Issues.count_issues(repository, state: "closed") end),
      updated_at: latest_commit_date(repository),
      imported: imported?(repository)
    )
  end

  defp latest_commit_date(repository) do
    safe(fn ->
      case OpenAgents.Forge.Browse.log(repository, repository.default_branch, 1) do
        {:ok, [latest | _rest]} -> latest.committed_at
        _other -> nil
      end
    end)
  end

  defp imported?(repository) do
    case Map.get(repository, :repository_import) do
      %OpenAgents.Repositories.RepositoryImport{} -> true
      _other -> false
    end
  end

  # Stats are decoration over another context's data; any failure degrades
  # that stat to nil instead of failing the card.
  defp safe(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  ## Meta-tag projection -------------------------------------------------------

  @doc """
  The map the root layout renders into `og:*` / `twitter:*` tags.
  `page_url` is the canonical absolute URL of the page emitting the tags.
  """
  def meta(%__MODULE__{} = card, page_url) do
    description = card.description || default_description()

    %{
      title: card.title || card.heading || "OpenAgents",
      description: description,
      type: "object",
      url: page_url,
      image_url: card_url(card),
      alt: description
    }
  end

  @doc "Absolute URL of the committed fallback card."
  def static_card_url, do: base_url() <> "/og/static/card.png"

  @doc "The configured absolute origin, e.g. https://openagents.com."
  def site_url, do: base_url()

  @doc "Meta tags for a card, canonicalized against the card's own page path."
  def meta(%__MODULE__{} = card), do: meta(card, base_url() <> (card.page_path || "/"))

  @doc "Absolute signed URL for a card's image."
  def card_url(%__MODULE__{kind: :site}), do: static_card_url()

  def card_url(%__MODULE__{} = card) do
    path = request_path(card)
    base_url() <> path <> "?sig=" <> signature(path)
  end

  @doc """
  The canonical request path for a card, versioned by its content digest:

      /og/v/{version}/repos/{owner}/{repo}[/{rest}].png
  """
  def request_path(%__MODULE__{} = card) do
    version = version(card)

    segments =
      ["og", "v", version, "repos" | Enum.map(card.path_suffix, &path_segment/1)]

    "/" <> Enum.join(segments, "/") <> ".png"
  end

  defp path_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  @doc "Content digest over exactly what the template will draw."
  def version(%__MODULE__{} = card) do
    inputs = {
      card.kind,
      card.kicker,
      card.heading,
      card.description,
      card.avatar,
      card.provenance,
      Enum.map(card.chips, &{&1.label, Map.get(&1, :tone)}),
      card.stats,
      template_revision()
    }

    serialized =
      inputs
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    binary_part(serialized, 0, @version_bytes)
  end

  @doc "HMAC over the request path; a query string never participates."
  def signature(request_path) when is_binary(request_path) do
    :crypto.mac(:hmac, :sha256, signing_key(), request_path)
    |> binary_part(0, @signature_bytes)
    |> Base.url_encode64(padding: false)
  end

  @doc "Constant-time signature check; anything malformed is simply invalid."
  def valid_signature?(request_path, sig) when is_binary(request_path) and is_binary(sig) do
    expected = signature(request_path)

    if byte_size(sig) == byte_size(expected) do
      Plug.Crypto.secure_compare(expected, sig)
    else
      false
    end
  end

  def valid_signature?(_request_path, _sig), do: false

  defp signing_key do
    secret =
      OpenAgentsWeb.Endpoint.config(:secret_key_base) ||
        Application.get_env(:openagents, :og_signing_key) ||
        "openagents-og-development-key"

    :crypto.mac(:hmac, :sha256, secret, "openagents-og-cards-v1")
  end

  # Bump when the rendering changes, not only when a card's content does. The
  # version segment is a content digest, so a fix to the renderer produces the
  # same URL as the bug did -- and every cache holding the bad bytes, including
  # Slack's and a reader's browser, keeps serving them under a `max-age=21600,
  # immutable` response that will not revalidate. Revision 2 is the corrupt-PNG
  # fix: cards rendered before it carried librsvg's stderr ahead of the image.
  defp template_revision, do: "2"

  defp base_url, do: String.trim_trailing(OpenAgentsWeb.Endpoint.url(), "/")

  defp default_description, do: "Code hosting, issues, and projects on the agent-native forge."

  defp meta_title(text) when is_binary(text), do: clamp(text, 120)

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(text) when is_binary(text), do: String.trim(text)

  defp namespace_slug(%{namespace: %{slug: slug}}) when is_binary(slug), do: slug
  defp namespace_slug(%{owner: owner}) when is_binary(owner), do: owner

  defp author_login(%{user: %{} = user}), do: user["login"] || user[:login]
  defp author_login(%{author: author}) when is_binary(author), do: author
  defp author_login(_), do: nil

  defp state_label(%{state: "closed", state_reason: "not_planned"}), do: "Closed as not planned"
  defp state_label(%{state: "closed", state_reason: "duplicate"}), do: "Closed as duplicate"
  defp state_label(%{state: "closed"}), do: "Closed"
  defp state_label(_), do: "Open"

  defp state_tone(%{state: "closed", state_reason: reason})
       when reason in ["not_planned", "duplicate"],
       do: :muted

  defp state_tone(%{state: "closed"}), do: :done
  defp state_tone(_), do: :open

  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 7)

  defp plural(1, singular, _plural), do: "1 #{singular}"
  defp plural(n, _singular, plural_form) when is_integer(n), do: "#{n} #{plural_form}"

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{div(bytes, 1024)} KB"

  defp format_size(bytes),
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  @doc """
  Language inferred from a path's extension or a well-known filename.
  Honest about ignorance: unknown shapes yield nil and the card shows no
  language chip.
  """
  def language_for_path(path) when is_binary(path) do
    filename = basename(path)

    well_known_language(filename) || extension_language(Path.extname(filename))
  end

  defp well_known_language("Dockerfile"), do: "Docker"
  defp well_known_language("Makefile"), do: "Makefile"
  defp well_known_language("mix.exs"), do: "Elixir"
  defp well_known_language(_), do: nil

  @extension_languages %{
    ".ex" => "Elixir",
    ".exs" => "Elixir",
    ".heex" => "HEEx",
    ".leex" => "HEEx",
    ".eex" => "EEx",
    ".erl" => "Erlang",
    ".hrl" => "Erlang",
    ".md" => "Markdown",
    ".markdown" => "Markdown",
    ".json" => "JSON",
    ".toml" => "TOML",
    ".yml" => "YAML",
    ".yaml" => "YAML",
    ".ts" => "TypeScript",
    ".tsx" => "TSX",
    ".js" => "JavaScript",
    ".jsx" => "JSX",
    ".mjs" => "JavaScript",
    ".cjs" => "JavaScript",
    ".rs" => "Rust",
    ".go" => "Go",
    ".py" => "Python",
    ".rb" => "Ruby",
    ".sh" => "Shell",
    ".bash" => "Shell",
    ".zsh" => "Shell",
    ".css" => "CSS",
    ".scss" => "SCSS",
    ".html" => "HTML",
    ".sql" => "SQL",
    ".swift" => "Swift",
    ".kt" => "Kotlin",
    ".java" => "Java",
    ".c" => "C",
    ".h" => "C",
    ".cpp" => "C++",
    ".hpp" => "C++",
    ".cs" => "C#",
    ".php" => "PHP",
    ".txt" => "Text",
    ".svg" => "SVG",
    ".xml" => "XML"
  }

  defp extension_language(ext) when is_binary(ext),
    do: Map.get(@extension_languages, String.downcase(ext))

  defp extension_language(_), do: nil

  defp basename(path) when is_binary(path),
    do: path |> String.split("/") |> Enum.reject(&(&1 == "")) |> List.last()

  # ── text safety and layout ──────────────────────────────────────────────────

  @control_pattern ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

  @doc "XML-escapes untrusted text; control characters are stripped entirely."
  def escape(text) when is_binary(text) do
    text
    |> String.replace(@control_pattern, "")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  def escape(nil), do: ""

  @doc "Hard cap on any dynamic string entering a template, grapheme-safe."
  def clamp(text, max_chars) when is_integer(max_chars) and max_chars >= 1 do
    cond do
      is_nil(text) ->
        nil

      String.length(text) <= max_chars ->
        String.trim(text)

      true ->
        text
        |> String.graphemes()
        |> Enum.take(max_chars - 1)
        |> Enum.concat(["…"])
        |> Enum.join()
    end
  end

  @doc """
  Greedy word-wrap to `max_lines` lines of at most `max_chars`, appending an
  ellipsis to the final line only when content actually remains. Empty input
  wraps to no lines.
  """
  def wrap(text, max_chars, max_lines)
      when is_integer(max_chars) and max_chars >= 1 and is_integer(max_lines) and max_lines >= 1 and
             is_binary(text) do
    words = String.split(String.trim(text), ~r/\s+/, trim: true)
    {lines, remaining?} = greedy_lines(words, max_chars, max_lines, [])

    if remaining?,
      do: List.replace_at(lines, -1, ellipsis_line(List.last(lines), max_chars)),
      else: lines
  end

  def wrap(nil, _max_chars, _max_lines), do: []

  defp greedy_lines([], _max_chars, _lines_left, acc), do: {Enum.reverse(acc), false}
  defp greedy_lines(_words, _max_chars, 0, acc), do: {Enum.reverse(acc), true}

  defp greedy_lines(words, max_chars, lines_left, acc) do
    {line, rest} = take_words(words, max_chars, "")
    greedy_lines(rest, max_chars, lines_left - 1, [line | acc])
  end

  defp take_words([], _max_chars, current), do: {String.trim_trailing(current), []}

  defp take_words([word | rest], max_chars, current) do
    cond do
      # A lone word longer than the budget is hard-split across lines: no
      # line may overflow its box, however long the unbroken token.
      current == "" and String.length(word) > max_chars ->
        {String.slice(word, 0, max_chars), [String.slice(word, max_chars..-1//1) | rest]}

      String.length(current <> " " <> word) > max_chars and current != "" ->
        {current, [word | rest]}

      current == "" ->
        take_words(rest, max_chars, word)

      true ->
        take_words(rest, max_chars, current <> " " <> word)
    end
  end

  defp ellipsis_line(line, max_chars) do
    keep = max(max_chars - 1, 1)

    line
    |> String.graphemes()
    |> Enum.take(keep)
    |> Enum.concat(["…"])
    |> Enum.join()
  end

  @doc """
  Flattens a path for display, always keeping the filename: long interiors
  collapse into a leading ellipsis plus the deepest directory that fits,
  never pushing the name off the card.
  """
  def display_path(path, max_chars \\ 64)
      when is_binary(path) and is_integer(max_chars) and max_chars >= 8 do
    segments = path |> String.split("/") |> Enum.reject(&(&1 == ""))

    if segments == [] do
      ""
    else
      filename = List.last(segments)

      if String.length(path) <= max_chars do
        path
      else
        interior = segments |> Enum.drop(-1) |> Enum.join("/")
        budget = max_chars - String.length(filename) - 2

        cond do
          interior == "" -> filename
          String.length(interior) <= budget -> interior <> "/" <> filename
          true -> "…/" <> tail_within(Enum.drop(segments, -1), budget) <> "/" <> filename
        end
      end
    end
  end

  # Deepest directories that still fit, read from the right.
  defp tail_within(segments, budget) do
    segments
    |> Enum.reverse()
    |> Enum.reduce_while([], fn segment, acc ->
      candidate = Enum.join([segment | acc], "/")

      if String.length(candidate) <= budget or acc == [] do
        {:cont, [segment | acc]}
      else
        {:halt, acc}
      end
    end)
    |> Enum.join("/")
  end
end
