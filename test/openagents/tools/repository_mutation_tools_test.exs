defmodule OpenAgents.Tools.RepositoryMutationToolsTest do
  @moduledoc """
  The repository mutation family (#122, SELF-EDIT-001): edits confined to a
  job's own clone of the forge with the exact-match policy, and a real
  commit+push over real HTTP to the forge with the WAL receipt and branch
  discipline — plus every refusal the invariant promises.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Tools.{ExecutionContext, Registry, RepoCommitPush, RepoEdit, RepoWrite, Runner}

  defmodule TestPipeline do
    @moduledoc false
    use Plug.Builder

    plug OpenAgentsWeb.Plugs.ForgeGitAuth
    plug OpenAgents.Forge.GitHTTP
  end

  @operator_token "forge_test_operator_token_0123456789"
  @job_ref "work-job:11111111-2222-3333-4444-555555555555"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "repo-mut-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    previous =
      for key <- [:forge_data_dir, :forge_wal_dir, :coding_jobs_dir, :forge_self_push_url] do
        {key, Application.get_env(:openagents, key)}
      end

    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))
    Application.put_env(:openagents, :coding_jobs_dir, Path.join(base, "jobs"))

    port = free_port()
    start_supervised!({Bandit, plug: TestPipeline, port: port, ip: {127, 0, 0, 1}})

    Application.put_env(
      :openagents,
      :forge_self_push_url,
      "http://x:#{@operator_token}@127.0.0.1:#{port}/openagents.com.git"
    )

    # Seed the forge's "openagents.com" repo with one commit so clones have a base.
    seed_repo!()

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:openagents, key, value),
          else: Application.delete_env(:openagents, key)
      end

      File.rm_rf(base)
    end)

    {:ok, snapshot} = Registry.build([RepoEdit, RepoWrite, RepoCommitPush])
    %{snapshot: snapshot}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp seed_repo! do
    path = Repos.ensure_repo!("openagents.com")

    {blob, 0} = plumb(path, ["hash-object", "-w", "--stdin"], "original content\n")
    {tree, 0} = plumb(path, ["mktree"], "100644 blob #{String.trim(blob)}\tnote.txt\n")

    {commit, 0} =
      plumb(path, ["commit-tree", String.trim(tree), "-m", "seed"], "",
        env: [
          {"GIT_AUTHOR_NAME", "t"},
          {"GIT_AUTHOR_EMAIL", "t@t"},
          {"GIT_COMMITTER_NAME", "t"},
          {"GIT_COMMITTER_EMAIL", "t@t"}
        ]
      )

    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", String.trim(commit)])
    :ok
  end

  defp plumb(path, args, stdin, opts \\ []) do
    input = Path.join(System.tmp_dir!(), "plumb-#{System.unique_integer([:positive])}")
    File.write!(input, stdin)

    try do
      System.cmd(
        "sh",
        ["-c", ~s(exec git --git-dir "$GD" "$@" < "$IN"), "sh"] ++ args,
        env: [{"GD", path}, {"IN", input}] ++ Keyword.get(opts, :env, [])
      )
    after
      File.rm(input)
    end
  end

  defp context(job_ref \\ @job_ref) do
    scope_ref = "conversation:test"

    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: scope_ref,
      authorities: MapSet.new(["repository.write"]),
      job_ref: job_ref,
      approval_receipts:
        if(job_ref,
          do: OpenAgents.Tools.Repository.approval_receipts(scope_ref, job_ref),
          else: []
        )
    }
  end

  defp run(snapshot, name, arguments, ctx) do
    {:ok, outcome} =
      Runner.run(
        snapshot,
        %{
          call_id: "call-#{name}-#{System.unique_integer([:positive])}",
          name: name,
          version: 1,
          raw_arguments: Jason.encode!(arguments)
        },
        ctx
      )

    outcome
  end

  test "the exact-match edit policy: no match, ambiguity, replace_all", %{snapshot: snapshot} do
    ctx = context()

    write =
      run(snapshot, "repo_write", %{"path" => "sample.txt", "content" => "aaa\nbbb\naaa\n"}, ctx)

    assert write["status"] == "succeeded"

    no_match =
      run(
        snapshot,
        "repo_edit",
        %{"path" => "sample.txt", "old_string" => "zzz", "new_string" => "q"},
        ctx
      )

    assert no_match["error"]["code"] == "no_match"

    ambiguous =
      run(
        snapshot,
        "repo_edit",
        %{"path" => "sample.txt", "old_string" => "aaa", "new_string" => "q"},
        ctx
      )

    assert ambiguous["error"]["code"] == "ambiguous_match"
    assert ambiguous["error"]["message"] =~ "more surrounding context"

    all =
      run(
        snapshot,
        "repo_edit",
        %{
          "path" => "sample.txt",
          "old_string" => "aaa",
          "new_string" => "ccc",
          "replace_all" => true
        },
        ctx
      )

    assert all["status"] == "succeeded"
    assert all["result"]["replacements"] == 2
  end

  test "mutation tools refuse outside a coding job's workspace", %{snapshot: snapshot} do
    outcome =
      run(
        snapshot,
        "repo_write",
        %{"path" => "x.txt", "content" => "boo"},
        context(nil)
      )

    # Outside a coding job there is no job approval receipt, so the surface
    # policy refuses before the tool even runs — mutation is doubly gated
    # (receipt here, workspace check inside the executor).
    assert outcome["status"] == "refused"
    assert outcome["error"]["code"] == "module_approval_required"
  end

  test "commit+push lands on the job branch with a WAL-backed receipt; other branches refused",
       %{snapshot: snapshot} do
    ctx = context()

    _write =
      run(snapshot, "repo_write", %{"path" => "feature.txt", "content" => "new feature\n"}, ctx)

    refused =
      run(
        snapshot,
        "repo_commit_push",
        %{"message" => "nope", "branch" => "main"},
        ctx
      )

    assert refused["error"]["code"] == "branch_refused"

    pushed = run(snapshot, "repo_commit_push", %{"message" => "Job edit"}, ctx)
    assert pushed["status"] == "succeeded"
    sha = pushed["result"]["sha"]
    assert sha =~ ~r/^[0-9a-f]{40}$/
    branch = pushed["result"]["branch"]
    assert branch == "openagents/job-11111111-2222-3333-4444-555555555555"

    # The commit SHA is in the outcome receipt refs (SELF-EDIT-001). The
    # middle segment is the forge repo the coding lane edits
    # (`OpenAgents.Tools.Repository.repo/0`), which is now `openagents.com` — the
    # same repository this test uses for the branch, the push receipt, and the
    # bare path below. Renaming the forge repo is a separate whole-repo
    # change (config `forge_repos`, visibility, public paths, git URL).
    assert "forge-commit:openagents.com:#{sha}" in pushed["target_receipt_refs"]

    # The push is receipted with a WAL sequence, and the ref exists on the
    # forge with exactly that sha.
    assert [receipt | _rest] = Forge.recent_pushes("openagents.com")
    assert is_integer(receipt.wal_seq)
    assert %{"new" => ^sha} = Map.get(receipt.refs, "refs/heads/" <> branch)

    path = Repos.bare_path("openagents.com")
    {out, 0} = Repos.git(path, ["rev-parse", "refs/heads/" <> branch])
    assert String.trim(out) == sha

    # Nothing further to commit is a typed outcome, not a crash.
    empty = run(snapshot, "repo_commit_push", %{"message" => "again"}, ctx)
    assert empty["error"]["code"] == "nothing_to_commit"

    # The push URL (which carries the forge credential) appears nowhere in
    # the outcome.
    refute inspect(pushed) =~ @operator_token
  end
end
