defmodule OpenAgents.Forge.Repos do
  @moduledoc """
  Bare git repositories on the node's stateful partition — the warm cache
  side of the forge. Ref truth is the WAL (`OpenAgents.Forge.WAL`); everything
  here can be deleted and re-materialized from it (`OpenAgents.Forge.Sync`).

  All git invocations are argv-only against `--git-dir`; no shell strings
  ever carry request data.
  """

  require Logger

  @name_pattern ~r/^[a-z0-9](?:[a-z0-9_-]|\.(?=[a-z0-9])){0,63}$/
  @storage_key_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  @doc "The forge data directory (bare repos + WAL cache + beam artifacts)."
  def data_dir do
    Application.get_env(:openagents, :forge_data_dir) ||
      "/var/lib/openagents/forge"
  end

  @doc "Repositories this forge serves. Bounded, config-owned."
  def allowed_repos do
    Application.get_env(:openagents, :forge_repos, ["openagents.com"])
  end

  def valid_name?(name) when is_binary(name) do
    Regex.match?(@name_pattern, name) and name in allowed_repos()
  end

  def valid_name?(_), do: false

  @doc "Whether an opaque repository storage key is safe as one path segment."
  def valid_storage_key?(storage_key) when is_binary(storage_key),
    do: Regex.match?(@storage_key_pattern, storage_key)

  def valid_storage_key?(_storage_key), do: false

  @doc "Absolute path of the bare repository for `repo`."
  def bare_path(repo), do: Path.join([data_dir(), "repos", repo <> ".git"])

  @doc "Delete one repository's disposable local bare-repository cache."
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
  def ensure_repo!(repo, default_branch \\ "main") do
    repo |> bare_path() |> ensure_repo_at!(default_branch)
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

  def set_default_branch!(repo, default_branch) do
    repo |> bare_path() |> set_default_branch_at!(default_branch)
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
  def refs(repo) do
    repo |> bare_path() |> refs_at()
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
  def set_refs!(repo, target_refs) when is_map(target_refs) do
    repo |> bare_path() |> set_refs_at!(target_refs)
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
  def applied_seq(repo) do
    repo |> bare_path() |> applied_seq_at()
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

  def record_applied_seq!(repo, seq) when is_integer(seq) do
    repo |> bare_path() |> record_applied_seq_at!(seq)
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
