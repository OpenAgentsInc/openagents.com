defmodule OpenAgents.Forge.Repos do
  @moduledoc """
  Bare git repositories on the node's stateful partition — the warm cache
  side of the forge. Ref truth is the WAL (`OpenAgents.Forge.WAL`); everything
  here can be deleted and re-materialized from it (`OpenAgents.Forge.Sync`).

  All git invocations are argv-only against `--git-dir`; no shell strings
  ever carry request data.

  ## Names are not storage keys

  Every function here that reaches the disk takes a **storage key** — the
  opaque, unique segment `Repository.storage_key` holds — and never a
  repository **name**. `allowed_repos/0` and `valid_name?/1` are the only two
  that speak in names, and a name is what a person has: `openagents.com`, or
  the `owner/name` path they clone.

  The two are both strings and a name is a legal path segment, so passing one
  where the other belongs builds a path rather than failing. `bare_path/1` on a
  name produces a directory beside the real repository that projects nothing —
  which is what issue #190 found on the live node. `OpenAgents.Forge.RepoRef`
  is the one place a name becomes a key; call it before calling anything here.
  """

  require Logger

  @typedoc "What a person has: a repository name, or an `owner/name` path."
  @type name :: String.t()

  @typedoc "What this module keys every path with: see `OpenAgents.Forge.RepoRef`."
  @type storage_key :: String.t()

  @name_pattern ~r/^[a-z0-9](?:[a-z0-9_-]|\.(?=[a-z0-9])){0,63}$/
  @storage_key_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  @doc "The forge data directory (bare repos + WAL cache + beam artifacts)."
  def data_dir do
    Application.get_env(:openagents, :forge_data_dir) ||
      "/var/lib/openagents/forge"
  end

  @doc """
  Repository *names* this forge serves operationally. Bounded, config-owned.

  These are names, not storage keys: `["openagents.com"]` is the name of the
  repository whose storage key is a UUID. Resolve one with
  `OpenAgents.Forge.RepoRef.storage_key/1` before using it as a path segment.
  """
  @spec allowed_repos() :: [name()]
  def allowed_repos do
    Application.get_env(:openagents, :forge_repos, ["openagents.com"])
  end

  @doc "Whether `name` is a well-formed name this forge serves operationally."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name) do
    Regex.match?(@name_pattern, name) and name in allowed_repos()
  end

  def valid_name?(_), do: false

  @doc """
  Whether an opaque repository storage key is safe as one path segment.

  Shape only. A repository name is shaped like a storage key, so this admits
  one; only `OpenAgents.Forge.RepoRef` can tell you which you are holding.
  """
  @spec valid_storage_key?(term()) :: boolean()
  def valid_storage_key?(storage_key) when is_binary(storage_key),
    do: Regex.match?(@storage_key_pattern, storage_key)

  def valid_storage_key?(_storage_key), do: false

  @doc "Absolute path of the bare repository for `storage_key`."
  @spec bare_path(storage_key()) :: String.t()
  def bare_path(storage_key), do: Path.join([data_dir(), "repos", storage_key <> ".git"])

  @doc "Delete one repository's disposable local bare-repository cache."
  @spec delete_repo(storage_key()) :: :ok | {:error, term()}
  def delete_repo(storage_key) do
    if valid_storage_key?(storage_key) do
      case File.rm_rf(bare_path(storage_key)) do
        {:ok, _removed} -> :ok
        {:error, reason, _path} -> {:error, reason}
      end
    else
      {:error, :invalid_storage_key}
    end
  end

  @doc "Initialize the bare repository if absent. Returns the path."
  @spec ensure_repo!(storage_key(), String.t()) :: String.t()
  def ensure_repo!(storage_key, default_branch \\ "main") do
    storage_key |> bare_path() |> ensure_repo_at!(default_branch)
  end

  @doc false
  def ensure_repo_at!(path, default_branch \\ "main") do
    quarantine_invalid_cache!(path)

    unless File.exists?(Path.join(path, "HEAD")) do
      File.mkdir_p!(path)
      {_, 0} = git(path, ["init", "--bare", "--initial-branch=#{default_branch}", path])
    end

    set_default_branch_at!(path, default_branch)
    hide_internal_refs_at!(path)

    path
  end

  # The cache is a disposable projection of the WAL. A directory that has a
  # HEAD file but that git refuses as a bare repository (for example one whose
  # refs directory was lost mid-write) would otherwise crash every read of the
  # repository forever. Move it aside so the caller reinitializes an empty
  # repository and WAL replay re-materializes every ref.
  defp quarantine_invalid_cache!(path) do
    if File.exists?(Path.join(path, "HEAD")) and not bare_repository_at?(path) do
      suffix = System.unique_integer([:positive, :monotonic])
      quarantine_path = path <> ".corrupt-#{suffix}"

      case File.rename(path, quarantine_path) do
        :ok ->
          Logger.warning(
            "forge_repo_cache_quarantined path=#{path} quarantine=#{quarantine_path}"
          )

          :ok

        {:error, reason} ->
          raise "cannot quarantine invalid repository cache #{path}: #{inspect(reason)}"
      end
    end

    :ok
  end

  defp bare_repository_at?(path) do
    match?({"true" <> _rest, 0}, git(path, ["rev-parse", "--is-bare-repository"]))
  end

  @spec set_default_branch!(storage_key(), String.t()) :: :ok
  def set_default_branch!(storage_key, default_branch) do
    storage_key |> bare_path() |> set_default_branch_at!(default_branch)
  end

  @doc false
  def set_default_branch_at!(path, default_branch) do
    {_, 0} = git(path, ["symbolic-ref", "HEAD", "refs/heads/#{default_branch}"])
    :ok
  end

  # Hidden internal refs (`refs/internal/`) retain stack boundary commits
  # (`OpenAgents.Forge.GitPlane`) without advertising them to git clients.
  defp hide_internal_refs_at!(path) do
    case git(path, ["config", "--get", "transfer.hideRefs"]) do
      {"refs/internal/" <> _rest, 0} ->
        :ok

      _unset ->
        {_, 0} = git(path, ["config", "transfer.hideRefs", "refs/internal/"])
        :ok
    end
  end

  @doc "Current refs of the bare repo as a `%{name => sha}` map."
  @spec refs(storage_key()) :: %{String.t() => String.t()}
  def refs(storage_key) do
    storage_key |> bare_path() |> refs_at()
  end

  @doc false
  def refs_at(path) do
    case git(path, ["for-each-ref", "--format=%(objectname) %(refname)"]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [sha, name] = String.split(line, " ", parts: 2)
          {name, sha}
        end)

      _error ->
        %{}
    end
  end

  @doc """
  Force the repo's refs to exactly `target_refs` (used for post-failure
  rollback and WAL materialization convergence). Deletes refs not present
  in the target.
  """
  @spec set_refs!(storage_key(), map()) :: :ok
  def set_refs!(storage_key, target_refs) when is_map(target_refs) do
    storage_key |> bare_path() |> set_refs_at!(target_refs)
  end

  @doc false
  def set_refs_at!(path, target_refs) when is_map(target_refs) do
    current = refs_at(path)

    Enum.each(current, fn {name, _sha} ->
      unless Map.has_key?(target_refs, name) do
        {_, 0} = git(path, ["update-ref", "-d", name])
      end
    end)

    # Replay converges refs after every WAL entry, so skipping the refs that
    # already match keeps a full rebuild at one `update-ref` per changed ref
    # instead of one per ref per entry.
    Enum.each(target_refs, fn {name, sha} ->
      unless Map.get(current, name) == sha do
        {_, 0} = git(path, ["update-ref", name, sha])
      end
    end)

    :ok
  end

  @doc "The WAL sequence this bare repo has applied (cache freshness marker)."
  @spec applied_seq(storage_key()) :: integer()
  def applied_seq(storage_key) do
    storage_key |> bare_path() |> applied_seq_at()
  end

  @doc false
  def applied_seq_at(path) do
    case File.read(Path.join(path, "openagents-wal-seq")) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {seq, _} -> seq
          :error -> -1
        end

      {:error, _} ->
        -1
    end
  end

  @spec record_applied_seq!(storage_key(), integer()) :: :ok
  def record_applied_seq!(storage_key, seq) when is_integer(seq) do
    storage_key |> bare_path() |> record_applied_seq_at!(seq)
  end

  @doc false
  def record_applied_seq_at!(path, seq) when is_integer(seq) do
    File.write!(Path.join(path, "openagents-wal-seq"), Integer.to_string(seq))
  end

  @doc """
  The WAL sequence at which this bare repo's shallow graft was last checked.

  Separate from the applied sequence because the two answer different
  questions. The applied sequence says which entries materialized; this says
  whether the objects they materialized can be walked from the refs, which is
  what `git upload-pack` needs and what `OpenAgents.Forge.Sync` reconciles.
  A cache written before this marker existed reports `-1` and is therefore
  checked once, which is how an already-damaged projection repairs itself.
  """
  def graft_seq_at(path) do
    case File.read(Path.join(path, "openagents-graft-seq")) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {seq, _} -> seq
          :error -> -1
        end

      {:error, _} ->
        -1
    end
  end

  @doc false
  def record_graft_seq_at!(path, seq) when is_integer(seq) do
    File.write!(Path.join(path, "openagents-graft-seq"), Integer.to_string(seq))
  end

  @doc "Run git with `--git-dir` pinned to the bare repo. Returns {output, status}."
  def git(git_dir, args, opts \\ []) do
    System.cmd(
      "git",
      ["--git-dir", git_dir | args],
      [stderr_to_stdout: true] ++ opts
    )
  end
end
