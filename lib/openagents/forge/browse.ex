defmodule OpenAgents.Forge.Browse do
  @moduledoc """
  Bounded, read-only git plumbing for the forge web UI (#136/#137): resolve
  refs, read blobs/trees/commits/diffs from the bare repos `OpenAgents.Forge.Repos`
  maintains. Pure reads — never writes a ref, never touches the WAL directly;
  `OpenAgents.Forge.Sync.ensure_fresh/1` runs first so a stale cache converges the
  same way it does for smart-HTTP reads.

  Every invocation is argv-only (the `Repos.git/3` discipline) and every
  output is size-bounded with honest truncation flags: a public page must
  never stream an unbounded `git show` to an anonymous socket.
  """

  require Logger

  alias OpenAgents.Forge.{Repos, Sync}
  alias OpenAgents.Repositories.Repository

  @ref_pattern ~r|^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$|
  @path_pattern ~r|^[^\x00]{1,512}$|
  @blob_cap 1_000_000
  @diff_cap 500_000
  @message_cap 65_536
  @list_cap 400

  @doc "Whether `ref` is shaped like a ref/sha we will pass to git at all."
  def valid_ref?(ref) when is_binary(ref) do
    Regex.match?(@ref_pattern, ref) and not String.contains?(ref, "..")
  end

  def valid_ref?(_), do: false

  @doc "Whether `path` is shaped like a repo-relative path we will pass to git."
  def valid_path?(path) when is_binary(path) do
    Regex.match?(@path_pattern, path) and not String.starts_with?(path, "/") and
      not String.contains?(path, "..") and not String.starts_with?(path, "-")
  end

  def valid_path?(_), do: false

  @doc "Resolve a branch name or (short) sha to a full commit sha."
  def resolve_commit(repo, ref) do
    with :ok <- check(repo, ref) do
      freshen(repo)

      case git(repo, ["rev-parse", "--verify", "--end-of-options", ref <> "^{commit}"]) do
        {output, 0} -> {:ok, String.trim(output)}
        _ -> {:error, :not_found}
      end
    end
  end

  # A node whose bare-repo cache is damaged (the 2026-08-19 incident, #134:
  # a torn loose object after a VM reset) makes WAL replay raise. That is a
  # node-local cache fault, not a reason to fail a public read: serve what
  # this node already has, and let the operator repair path fix the cache.
  defp freshen(repo) do
    Sync.ensure_fresh(storage_key(repo), default_branch(repo))
  rescue
    error ->
      Logger.warning(
        "forge_browse_sync_failed repo=#{storage_key(repo)} code=#{OpenAgents.OperationalLog.code(error)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "forge_browse_sync_exited repo=#{storage_key(repo)} code=#{OpenAgents.OperationalLog.code(reason)}"
      )

      :ok
  end

  @doc "The default branch head, if the repo has one."
  def head(repo) do
    _ = freshen(repo)
    refs = Repos.refs(storage_key(repo))

    case Map.fetch(refs, "refs/heads/#{default_branch(repo)}") do
      {:ok, sha} -> {:ok, sha}
      :error when map_size(refs) > 0 -> {:ok, refs |> Enum.sort() |> hd() |> elem(1)}
      _ -> {:error, :empty}
    end
  end

  @doc "Branches and tags as `[%{name, sha, kind}]`, bounded."
  def refs(repo) do
    repo
    |> storage_key()
    |> Repos.refs()
    |> Enum.flat_map(fn {name, sha} ->
      case name do
        "refs/heads/" <> short -> [%{name: short, sha: sha, kind: :branch}]
        "refs/tags/" <> short -> [%{name: short, sha: sha, kind: :tag}]
        _ -> []
      end
    end)
    |> Enum.sort_by(&{&1.kind, &1.name})
    |> Enum.take(@list_cap)
  end

  @doc """
  One commit's bounded metadata: message, author name, committed-at, parents,
  and its provenance trailers (`Co-Authored-By`, `Claude-Session`,
  `Changelog*` — the fields the transparency spec renders first-class).
  Author emails are deliberately not returned.
  """
  def commit(repo, sha) do
    with {:ok, full} <- resolve_commit(repo, sha) do
      format = "%H%x00%an%x00%cI%x00%P%x00%B"

      case git(repo, ["show", "-s", "--format=" <> format, "--end-of-options", full]) do
        {output, 0} ->
          [h, author, date, parents, message] = String.split(output, "\x00", parts: 5)
          message = truncate(String.trim_trailing(message), @message_cap)

          {:ok,
           %{
             sha: h,
             author: author,
             committed_at: date,
             parents: String.split(parents, " ", trim: true),
             subject: message |> String.split("\n", parts: 2) |> hd(),
             message: message,
             trailers: trailers(message)
           }}

        _ ->
          {:error, :not_found}
      end
    end
  end

  @doc "Changed files for a commit as `[%{status, path}]`, bounded."
  def changed_files(repo, sha) do
    with {:ok, full} <- resolve_commit(repo, sha) do
      case git(repo, [
             "diff-tree",
             "--no-commit-id",
             "--name-status",
             "-r",
             "-M",
             "--root",
             "--end-of-options",
             full
           ]) do
        {output, 0} ->
          files =
            output
            |> String.split("\n", trim: true)
            |> Enum.take(@list_cap)
            |> Enum.flat_map(fn line ->
              case String.split(line, "\t") do
                [status | paths] when paths != [] -> [%{status: status, path: List.last(paths)}]
                _ -> []
              end
            end)

          {:ok, files}

        _ ->
          {:error, :not_found}
      end
    end
  end

  @doc "The unified diff for a commit, byte-capped with a truncation flag."
  def diff(repo, sha) do
    with {:ok, full} <- resolve_commit(repo, sha) do
      case git(repo, ["diff-tree", "-p", "-M", "--root", "--no-color", "--end-of-options", full]) do
        {output, 0} -> {:ok, truncate(output, @diff_cap), byte_size(output) > @diff_cap}
        _ -> {:error, :not_found}
      end
    end
  end

  @doc "Directory listing at `ref`/`path` as `[%{name, kind, size}]`, bounded."
  def tree(repo, ref, path \\ "") do
    with {:ok, full} <- resolve_commit(repo, ref),
         :ok <- check_path(path, allow_empty: true) do
      spec = if path == "", do: full, else: full <> ":" <> path

      case git(repo, ["ls-tree", "-l", "--end-of-options", spec]) do
        {output, 0} ->
          entries =
            output
            |> String.split("\n", trim: true)
            |> Enum.take(@list_cap)
            |> Enum.flat_map(fn line ->
              with [meta, name] <- String.split(line, "\t", parts: 2),
                   [_mode, kind, _sha, size] <- String.split(meta, " ", trim: true) do
                [%{name: name, kind: kind, size: parse_size(size)}]
              else
                _ -> []
              end
            end)
            |> Enum.sort_by(&{&1.kind != "tree", &1.name})

          {:ok, entries}

        _ ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  A file's bounded content at `ref`/`path`:
  `{:ok, %{content, truncated, binary, size}}`.
  """
  def blob(repo, ref, path) do
    with {:ok, full} <- resolve_commit(repo, ref),
         :ok <- check_path(path) do
      spec = full <> ":" <> path

      with {size_out, 0} <- git(repo, ["cat-file", "-s", spec]),
           {size, _} <- Integer.parse(String.trim(size_out)),
           {output, 0} <- git(repo, ["cat-file", "blob", spec]) do
        content = truncate(output, @blob_cap)

        {:ok,
         %{
           content: content,
           truncated: size > @blob_cap,
           binary: binary_content?(content),
           size: size
         }}
      else
        _ -> {:error, :not_found}
      end
    end
  end

  @doc "The README blob at a commit, if one exists."
  def readme(repo, ref) do
    Enum.find_value(["README.md", "README"], {:error, :not_found}, fn name ->
      case blob(repo, ref, name) do
        {:ok, found} -> {:ok, name, found}
        _ -> nil
      end
    end)
  end

  @doc "Bounded commit list from `ref` as commit maps (no diffs)."
  def log(repo, ref, limit \\ 30) do
    limit = min(limit, 100)

    with {:ok, full} <- resolve_commit(repo, ref) do
      format = "%H%x00%an%x00%cI%x00%s%x01"

      case git(repo, [
             "log",
             "-n",
             Integer.to_string(limit),
             "--format=" <> format,
             "--end-of-options",
             full
           ]) do
        {output, 0} ->
          commits =
            output
            |> String.split("\x01", trim: true)
            |> Enum.flat_map(fn record ->
              case record |> String.trim_leading("\n") |> String.split("\x00", parts: 4) do
                [sha, author, date, subject] ->
                  [%{sha: sha, author: author, committed_at: date, subject: subject}]

                _ ->
                  []
              end
            end)

          {:ok, commits}

        _ ->
          {:error, :not_found}
      end
    end
  end

  @known_trailers ~w(Co-Authored-By Claude-Session Changelog Changelog-Category Changelog-Visibility)

  @doc "Parse provenance/changelog trailers out of a commit message."
  def trailers(message) do
    message
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^([A-Za-z][A-Za-z-]{1,40}):\s+(.{1,500})$/, String.trim(line)) do
        [_, key, value] when key in @known_trailers -> [{key, String.trim(value)}]
        _ -> []
      end
    end)
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp check(repo, ref) do
    cond do
      not Repos.valid_storage_key?(storage_key(repo)) -> {:error, :not_found}
      not valid_ref?(ref) -> {:error, :not_found}
      true -> :ok
    end
  end

  defp check_path(path, opts \\ []) do
    cond do
      path == "" and Keyword.get(opts, :allow_empty, false) -> :ok
      valid_path?(path) -> :ok
      true -> {:error, :not_found}
    end
  end

  defp git(repo, args), do: Repos.git(Repos.bare_path(storage_key(repo)), args)

  defp storage_key(%Repository{storage_key: storage_key}), do: storage_key
  defp storage_key(storage_key) when is_binary(storage_key), do: storage_key

  defp default_branch(%Repository{default_branch: default_branch}), do: default_branch
  defp default_branch(_storage_key), do: "main"

  defp truncate(binary, cap) when byte_size(binary) > cap,
    do: binary |> binary_part(0, cap) |> trim_to_valid_utf8()

  defp truncate(binary, _cap), do: binary

  # A byte-capped cut can split a multibyte character; trimming at most three
  # trailing bytes repairs that. Binary (non-UTF-8) content stays as-is — the
  # `binary` flag keeps it out of text rendering entirely.
  defp trim_to_valid_utf8(binary), do: trim_to_valid_utf8(binary, 3)

  defp trim_to_valid_utf8(binary, 0), do: binary

  defp trim_to_valid_utf8(binary, tries) do
    cond do
      String.valid?(binary) -> binary
      byte_size(binary) == 0 -> binary
      true -> trim_to_valid_utf8(binary_part(binary, 0, byte_size(binary) - 1), tries - 1)
    end
  end

  defp binary_content?(content) do
    content |> binary_part(0, min(byte_size(content), 8_192)) |> String.contains?(<<0>>)
  end

  defp parse_size("-"), do: nil

  defp parse_size(size) do
    case Integer.parse(size) do
      {n, _} -> n
      :error -> nil
    end
  end
end
