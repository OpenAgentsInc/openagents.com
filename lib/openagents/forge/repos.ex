defmodule OpenAgents.Forge.Repos do
  @moduledoc """
  Bare git repositories on the node's stateful partition — the warm cache
  side of the forge. Ref truth is the WAL (`OpenAgents.Forge.WAL`); everything
  here can be deleted and re-materialized from it (`OpenAgents.Forge.Sync`).

  All git invocations are argv-only against `--git-dir`; no shell strings
  ever carry request data.
  """

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
    unless File.exists?(Path.join(path, "HEAD")) do
      File.mkdir_p!(path)
      {_, 0} = git(path, ["init", "--bare", "--initial-branch=#{default_branch}", path])
    end

    set_default_branch_at!(path, default_branch)

    path
  end

  def set_default_branch!(repo, default_branch) do
    repo |> bare_path() |> set_default_branch_at!(default_branch)
  end

  @doc false
  def set_default_branch_at!(path, default_branch) do
    {_, 0} = git(path, ["symbolic-ref", "HEAD", "refs/heads/#{default_branch}"])
    :ok
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

    Enum.each(target_refs, fn {name, sha} ->
      {_, 0} = git(path, ["update-ref", name, sha])
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

  @doc "Run git with `--git-dir` pinned to the bare repo. Returns {output, status}."
  def git(git_dir, args, opts \\ []) do
    System.cmd(
      "git",
      ["--git-dir", git_dir | args],
      [stderr_to_stdout: true] ++ opts
    )
  end
end
