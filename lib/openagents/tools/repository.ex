defmodule OpenAgents.Tools.Repository do
  @moduledoc """
  Shared substrate for the repository tool family (#122, SELF-EDIT-001).

  Two distinct roots, disclosed distinctly:

  - **Baked source** (`source_dir/0`): the source tree of the code this node
    is actually running, baked into the image at `/app/src`. Read-only truth
    for "what am I running" — read tools default here.
  - **Per-job clone** (`workspace_dir/1`): a working tree cloned from the
    local forge bare repo (origin is never GitHub) under the job's own
    directory. The ONLY place mutation tools may act, and pushes from it go
    only to that job's `sarah/job-<id>` branch. Removed when the job ends.

  Path handling fails closed: every path is resolved and verified to stay
  inside its root before any filesystem call.
  """

  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.Sync

  @repo "sarah"

  @doc "The baked source root (the running code's own tree)."
  def source_dir do
    Application.get_env(:sarah, :sarah_source_dir, File.cwd!())
  end

  @doc "The workspace root that holds all per-job clones."
  def jobs_dir do
    Application.get_env(
      :sarah,
      :coding_jobs_dir,
      Path.join(System.tmp_dir!(), "sarah-coding-jobs")
    )
  end

  @doc "The forge repo the coding lane edits."
  def repo, do: @repo

  @doc "This job's clone directory (may not exist yet)."
  def workspace_dir("work-job:" <> job_id), do: Path.join(jobs_dir(), "job-" <> job_id)

  @doc "This job's push branch — the only ref it may ever push."
  def job_branch("work-job:" <> job_id), do: "sarah/job-" <> job_id

  @doc """
  Ensure the per-job clone exists, cloning from the LOCAL forge bare repo
  (WAL-fresh). Returns `{:ok, dir}` or a typed error.
  """
  def ensure_workspace(job_ref) when is_binary(job_ref) do
    dir = workspace_dir(job_ref)

    if File.dir?(Path.join(dir, ".git")) do
      {:ok, dir}
    else
      Sync.ensure_fresh(@repo)
      bare = Repos.bare_path(@repo)
      File.mkdir_p!(jobs_dir())

      case System.cmd("git", ["clone", "--quiet", bare, dir], stderr_to_stdout: true) do
        {_, 0} -> {:ok, dir}
        {output, _} -> {:error, {:workspace_clone_failed, String.slice(output, 0, 500)}}
      end
    end
  end

  def ensure_workspace(_job_ref), do: {:error, :repository_workspace_unavailable}

  @doc "Remove a job's clone. Idempotent; called when the job ends."
  def cleanup_workspace(job_ref) when is_binary(job_ref) do
    case job_ref do
      "work-job:" <> _id -> File.rm_rf(workspace_dir(job_ref))
      _other -> :ok
    end

    :ok
  end

  @doc """
  The root a read tool acts on: `"image"` is the baked source of the running
  code; `"workspace"` is this job's clone (requires a job context and
  creates the clone on first use).
  """
  def tool_root("image", _context), do: {:ok, source_dir()}

  def tool_root("workspace", %{job_ref: job_ref}) when is_binary(job_ref),
    do: ensure_workspace(job_ref)

  def tool_root("workspace", _context), do: {:error, :repository_workspace_unavailable}
  def tool_root(_from, _context), do: {:error, :invalid_repository_path}

  @doc """
  Resolve a repo-relative path inside `root`, refusing traversal outside it.
  """
  def safe_path(root, relative) when is_binary(relative) do
    cond do
      not is_binary(root) or root == "" ->
        {:error, :repository_unavailable}

      String.starts_with?(relative, "/") or String.contains?(relative, "\0") ->
        {:error, :invalid_repository_path}

      true ->
        expanded = Path.expand(relative, root)
        rootward = Path.expand(root)

        if expanded == rootward or String.starts_with?(expanded, rootward <> "/") do
          {:ok, expanded}
        else
          {:error, :invalid_repository_path}
        end
    end
  end

  def safe_path(_root, _relative), do: {:error, :invalid_repository_path}

  @doc """
  The exact-match edit policy (probe's semantics re-expressed in Elixir):
  LF-normalized matching; zero matches is a typed error; more than one match
  without `replace_all` asks for more context; the caller re-reads the file
  immediately before writing so stale expectations fail honestly.

  Returns `{:ok, new_content, replaced_count}` or a typed error.
  """
  def apply_edit(content, old_string, new_string, replace_all)
      when is_binary(content) and is_binary(old_string) and is_binary(new_string) do
    normalized = normalize(content)
    old = normalize(old_string)
    new = normalize(new_string)

    cond do
      old == "" ->
        {:error, :empty_match_string}

      old == new ->
        {:error, :edit_is_noop}

      true ->
        case count_matches(normalized, old) do
          0 -> {:error, :no_match}
          1 -> {:ok, String.replace(normalized, old, new), 1}
          count when replace_all -> {:ok, String.replace(normalized, old, new), count}
          _many -> {:error, :ambiguous_match}
        end
    end
  end

  defp normalize(string), do: String.replace(string, "\r\n", "\n")

  defp count_matches(content, pattern) do
    content |> String.split(pattern) |> length() |> Kernel.-(1)
  end

  @doc """
  Approval receipts for the repository mutation modules, minted for a coding
  job. Starting the coding job is the person's exact current consent for the
  reversible writes inside the job's own clone; the operator posture for the
  one external effect (a push to the job's own branch on Sarah's own forge)
  is host policy: the branch is sandboxed and promotion stays operator-only
  (SELF-EDIT-001).
  """
  def approval_receipts(scope_ref, job_ref)
      when is_binary(scope_ref) and is_binary(job_ref) do
    reversible =
      for module_id <- ["sarah.tool.repo_edit.v1", "sarah.tool.repo_write.v1"] do
        %{
          "schema" => "sarah.module_approval.v1",
          "approval_class" => "exact_current_user_consent",
          "module_id" => module_id,
          "version" => 1,
          "scope_ref" => scope_ref,
          "explicit" => true,
          "actor_type" => "person",
          "receipt_ref" => job_ref
        }
      end

    push = %{
      "schema" => "sarah.module_approval.v1",
      "approval_class" => "explicit_operator_approval",
      "module_id" => "sarah.tool.repo_commit_push.v1",
      "version" => 1,
      "scope_ref" => scope_ref,
      "explicit" => true,
      "actor_type" => "operator",
      "receipt_ref" => job_ref
    }

    reversible ++ [push]
  end

  def approval_receipts(_scope_ref, _job_ref), do: []

  @doc "Where `repo_commit_push` pushes: the forge's own endpoint, never GitHub."
  def push_url do
    Application.get_env(:sarah, :forge_self_push_url)
  end

  @doc "Run git in `dir` with prompts disabled; returns {output, status}."
  def git(dir, args) do
    System.cmd("git", ["-C", dir | args],
      stderr_to_stdout: true,
      env: [{"GIT_TERMINAL_PROMPT", "0"}]
    )
  end
end
