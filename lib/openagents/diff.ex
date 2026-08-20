defmodule OpenAgents.Diff do
  @moduledoc """
  A unified diff, decomposed into files, hunks, and lines.

  The model is adapted from Pierre's `@pierre/diffs` (Apache 2.0,
  `pierrecomputer/pierre`), which is the part of that library worth taking:
  what a diff *is* once you stop treating it as text. See
  `docs/2026-08-20-pierre-code-surfaces-port.md`.

  A diff arrives from `git diff-tree -p -M` as one string, and rendering it as
  one string is what the commit page used to do. The whole value of parsing it
  is that each line then carries **both** line numbers -- where it sits in the
  old file and in the new one -- which is what lets a reader point at a line,
  and what a `<pre>` blob can never provide.

  The parser is deliberately tolerant. A diff is a report about somebody else's
  repository: it can be truncated mid-hunk by an upstream cap, describe a
  binary file, record a rename with no content change, or use headers this code
  has not seen. None of that should raise on a page whose job is to show what
  happened. Anything unrecognised inside a file becomes a `:meta` line, which
  renders as plain text and is honest about being unparsed.
  """

  defmodule Line do
    @moduledoc "One line of a hunk, carrying its position in both files."

    @type kind :: :context | :insert | :delete | :meta

    @type t :: %__MODULE__{
            kind: kind(),
            text: String.t(),
            old_number: pos_integer() | nil,
            new_number: pos_integer() | nil
          }

    @enforce_keys [:kind, :text]
    defstruct [:kind, :text, :old_number, :new_number]
  end

  defmodule Hunk do
    @moduledoc """
    One contiguous run of changes.

    `heading` is the text git puts after the `@@` marker -- usually the
    enclosing function -- which is the cheapest orientation a reader gets and
    the reason the header is worth rendering rather than discarding.
    """

    @type t :: %__MODULE__{
            old_start: non_neg_integer(),
            old_count: non_neg_integer(),
            new_start: non_neg_integer(),
            new_count: non_neg_integer(),
            heading: String.t() | nil,
            lines: [Line.t()]
          }

    @enforce_keys [:old_start, :old_count, :new_start, :new_count]
    defstruct [:old_start, :old_count, :new_start, :new_count, :heading, lines: []]
  end

  defmodule File do
    @moduledoc """
    One file's worth of a diff.

    `status` distinguishes the cases a header can describe: `:added`,
    `:deleted`, `:renamed`, or `:modified`. `binary?` is its own flag rather
    than an absence of hunks, because "no textual change to show" and "this
    file cannot be shown as text" are different statements and a reader should
    be told which one they are looking at.
    """

    @type status :: :added | :deleted | :renamed | :modified

    @type t :: %__MODULE__{
            path: String.t(),
            old_path: String.t() | nil,
            status: status(),
            binary?: boolean(),
            hunks: [Hunk.t()],
            insertions: non_neg_integer(),
            deletions: non_neg_integer()
          }

    @enforce_keys [:path]
    defstruct [
      :path,
      :old_path,
      status: :modified,
      binary?: false,
      hunks: [],
      insertions: 0,
      deletions: 0
    ]
  end

  @doc """
  Parse a unified diff into `%File{}` structs, in the order git emitted them.

  Returns `[]` for empty or unparseable input rather than raising: a commit
  page that shows nothing is a worse answer than one that shows the files it
  understood, but both are better than a crash.
  """
  @spec parse(String.t() | nil) :: [File.t()]
  def parse(nil), do: []
  def parse(""), do: []

  def parse(diff) when is_binary(diff) do
    diff
    |> lines()
    |> collect_files(nil, [])
    |> Enum.map(&finalize_file/1)
  end

  # A newline-terminated diff splits to a trailing empty element, which is the
  # terminator rather than a line. Left in, it became a phantom context line on
  # the last hunk of every file and shifted that hunk's line count by one. Only
  # the final one is dropped: an empty element anywhere else is a real line
  # from a generator that writes bare blank lines instead of `" "`.
  defp lines(diff) do
    case String.split(diff, "\n") do
      [] -> []
      parts -> if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
    end
  end

  @doc """
  Totals across a parsed diff: how many files, and how many lines each way.

  Reported from the parsed lines rather than from git's own summary, so the
  number under a diff always describes the diff above it -- including when the
  input was truncated and the tail is missing.
  """
  @spec totals([File.t()]) :: %{
          files: non_neg_integer(),
          insertions: non_neg_integer(),
          deletions: non_neg_integer()
        }
  def totals(files) when is_list(files) do
    Enum.reduce(files, %{files: 0, insertions: 0, deletions: 0}, fn file, acc ->
      %{
        files: acc.files + 1,
        insertions: acc.insertions + file.insertions,
        deletions: acc.deletions + file.deletions
      }
    end)
  end

  # ── file boundaries ───────────────────────────────────────────────────────

  defp collect_files([], nil, done), do: Enum.reverse(done)
  defp collect_files([], current, done), do: Enum.reverse([current | done])

  defp collect_files(["diff --git " <> paths | rest], current, done) do
    file = %File{path: path_from_header(paths)}
    collect_files(rest, file, if(current, do: [current | done], else: done))
  end

  # Lines before the first `diff --git` are the commit's own headers, not a
  # file's, and are dropped rather than attached to something they precede.
  defp collect_files([_line | rest], nil, done), do: collect_files(rest, nil, done)

  defp collect_files([line | rest], current, done) do
    collect_files(rest, absorb(current, line), done)
  end

  # `diff --git a/x b/x`, where either side may be quoted and contain spaces.
  # The b-side is preferred: it is the path the file has now.
  defp path_from_header(paths) do
    case Regex.run(~r|^"?a/(.*?)"? "?b/(.*?)"?$|, String.trim(paths), capture: :all_but_first) do
      [_old, new] -> new
      nil -> String.trim(paths)
    end
  end

  # ── headers and body ──────────────────────────────────────────────────────

  defp absorb(file, "new file mode" <> _rest), do: %{file | status: :added}
  defp absorb(file, "deleted file mode" <> _rest), do: %{file | status: :deleted}

  defp absorb(file, "rename from " <> old),
    do: %{file | status: :renamed, old_path: unquote_path(old)}

  defp absorb(file, "rename to " <> new), do: %{file | path: unquote_path(new)}

  defp absorb(file, "Binary files " <> _rest), do: %{file | binary?: true}
  defp absorb(file, "GIT binary patch" <> _rest), do: %{file | binary?: true}

  # Dropped: they restate the paths already in the `diff --git` header, and
  # `/dev/null` on either side restates the status.
  defp absorb(file, "--- " <> _rest), do: file
  defp absorb(file, "+++ " <> _rest), do: file
  defp absorb(file, "index " <> _rest), do: file
  defp absorb(file, "old mode " <> _rest), do: file
  defp absorb(file, "new mode " <> _rest), do: file
  defp absorb(file, "similarity index " <> _rest), do: file
  defp absorb(file, "dissimilarity index " <> _rest), do: file

  defp absorb(file, "@@" <> _rest = line) do
    case parse_hunk_header(line) do
      {:ok, hunk} -> %{file | hunks: [hunk | file.hunks]}
      :error -> push_line(file, %Line{kind: :meta, text: line})
    end
  end

  defp absorb(%File{hunks: []} = file, _line), do: file

  defp absorb(file, "+" <> text), do: push_line(file, :insert, text)
  defp absorb(file, "-" <> text), do: push_line(file, :delete, text)
  defp absorb(file, " " <> text), do: push_line(file, :context, text)
  defp absorb(file, ""), do: push_line(file, :context, "")

  # "\ No newline at end of file", and anything else that turns up inside a
  # hunk. Stated rather than swallowed.
  defp absorb(file, line), do: push_line(file, %Line{kind: :meta, text: line})

  defp unquote_path(path), do: path |> String.trim() |> String.trim("\"")

  # `@@ -old,count +new,count @@ optional heading`, where either count may be
  # omitted and means 1.
  defp parse_hunk_header(line) do
    case Regex.run(~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$/, line,
           capture: :all_but_first
         ) do
      [old_start, old_count, new_start, new_count | heading] ->
        {:ok,
         %Hunk{
           old_start: String.to_integer(old_start),
           old_count: count(old_count),
           new_start: String.to_integer(new_start),
           new_count: count(new_count),
           heading: heading |> List.first() |> presence()
         }}

      nil ->
        :error
    end
  end

  defp count(""), do: 1
  defp count(value), do: String.to_integer(value)

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  # ── line numbering ────────────────────────────────────────────────────────

  # Lines are appended unnumbered and numbered once, in `finalize_file/1`.
  # Numbering on the way in means re-counting the hunk for every line, which is
  # quadratic in the hunk's length -- fine for the four-line hunk in a test and
  # not fine for the thousand-line hunk in a real reformatting commit.
  defp push_line(file, kind, text) do
    [hunk | rest] = file.hunks
    line = %Line{kind: kind, text: text}

    %{
      file
      | hunks: [%{hunk | lines: [line | hunk.lines]} | rest],
        insertions: file.insertions + if(kind == :insert, do: 1, else: 0),
        deletions: file.deletions + if(kind == :delete, do: 1, else: 0)
    }
  end

  defp push_line(%File{hunks: []} = file, %Line{} = line) do
    # A meta line before any hunk has nowhere to sit; the file header already
    # said everything it could say.
    _ = line
    file
  end

  defp push_line(file, %Line{} = line) do
    [hunk | rest] = file.hunks
    %{file | hunks: [%{hunk | lines: [line | hunk.lines]} | rest]}
  end

  defp finalize_file(file) do
    hunks =
      file.hunks
      |> Enum.reverse()
      |> Enum.map(&number_hunk/1)

    %{file | hunks: hunks}
  end

  # One pass, carrying the next number on each side. A deletion advances only
  # the old side and an insertion only the new one, which is the whole reason a
  # line needs two numbers: they stop agreeing at the first change.
  defp number_hunk(hunk) do
    {numbered, _old, _new} =
      hunk.lines
      |> Enum.reverse()
      |> Enum.reduce({[], hunk.old_start, hunk.new_start}, fn line, {acc, old, new} ->
        case line.kind do
          :context ->
            {[%{line | old_number: old, new_number: new} | acc], old + 1, new + 1}

          :delete ->
            {[%{line | old_number: old} | acc], old + 1, new}

          :insert ->
            {[%{line | new_number: new} | acc], old, new + 1}

          :meta ->
            {[line | acc], old, new}
        end
      end)

    %{hunk | lines: Enum.reverse(numbered)}
  end
end
