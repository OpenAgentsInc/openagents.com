defmodule OpenAgents.CodingJobTest do
  @moduledoc """
  The P5 exit loop (#122, SELF-EDIT-001) minus the human Promote click:
  a coding job reads, edits, checks, commits, and pushes through the
  governed repository tools against a real forge over real HTTP — with the
  commit SHA in the outcome receipt, the WAL-backed push receipt, the
  coding-lieutenant role receipt, the grant ledger entry, and the workspace
  cleaned up at terminal. Promotion of the pushed SHA is the operator's
  action and is covered by the forge suite.
  """

  use OpenAgents.SarahDataCase, async: false
  import Ecto.Query

  alias OpenAgents.{Conversations, Work}
  alias OpenAgents.Forge
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Work.Job

  defmodule TestPipeline do
    @moduledoc false
    use Plug.Builder

    plug OpenAgentsWeb.Plugs.ForgeGitAuth
    plug OpenAgents.Forge.GitHTTP
  end

  @operator_token "forge_test_operator_token_0123456789"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "coding-job-#{System.unique_integer([:positive])}")
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
      "http://x:#{@operator_token}@127.0.0.1:#{port}/sarah.git"
    )

    seed_repo!()

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:openagents, key, value),
          else: Application.delete_env(:openagents, key)
      end

      File.rm_rf(base)
    end)

    :ok
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp seed_repo! do
    path = Repos.ensure_repo!("sarah")
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

  defp await_terminal_job(job_id) do
    Enum.reduce_while(1..100, nil, fn _attempt, _acc ->
      job = Repo.get!(Job, job_id)

      if job.status in ~w(completed failed interrupted budget_exhausted cancelled) do
        {:halt, job}
      else
        Process.sleep(50)
        {:cont, job}
      end
    end)
  end

  test "a coding job runs read → edit → check → push and the SHA chains through receipts" do
    assert {:ok, conversation} = Conversations.ensure_conversation("coding-job-loop")

    assert {:ok, job} =
             Work.start_coding(%{
               conversation_id: conversation.id,
               owner_visitor_id: conversation.visitor_id,
               surface: "text",
               goal: "[coding-job]"
             })

    assert job.kind == "coding"
    job = await_terminal_job(job.id)
    assert job.status == "completed"

    # The report names the pushed commit — the operator promotes from it.
    assert job.report =~ "Coding report: pushed "
    assert [_, sha] = Regex.run(~r/pushed ([0-9a-f]{40})/, job.report)
    assert job.report =~ "sarah/job-#{job.id}"

    # Step receipts: all four tools succeeded, executor disclosed, and the
    # push step carries the commit SHA in its target receipt refs
    # (SELF-EDIT-001: receipts reconstruct what ran).
    steps = Work.list_job_steps(job)
    assert Enum.map(steps, & &1.tool_name) == ~w(repo_read repo_edit code_check repo_commit_push)
    assert Enum.all?(steps, &(&1.status == "succeeded"))

    push_step = List.last(steps)
    # The middle segment is the forge repo the coding lane edits
    # (`OpenAgents.Tools.Repository.repo/0`) — still `sarah`, the same name
    # the push receipt below is looked up under.
    assert "forge-commit:sarah:#{sha}" in push_step.target_receipt_refs

    # The push is WAL-receipted on the forge, on the job's own branch.
    assert [push_receipt | _rest] = Forge.recent_pushes("sarah")
    assert is_integer(push_receipt.wal_seq)
    branch_ref = "refs/heads/sarah/job-#{job.id}"
    assert %{"new" => ^sha} = Map.get(push_receipt.refs, branch_ref)

    # Only the job branch moved — main is untouched (promotion is a human).
    path = Repos.bare_path("sarah")
    {main_sha, 0} = Repos.git(path, ["rev-parse", "refs/heads/main"])
    refute String.trim(main_sha) == sha

    # The per-job clone is removed at terminal.
    refute File.exists?(
             Path.join(Application.fetch_env!(:openagents, :coding_jobs_dir), "job-#{job.id}")
           )

    # The job's inference usage landed in the same grant ledger as everyone
    # else's, and the grant is settled (not left active).
    assert %{"inference_grant_id" => grant_id} = Repo.get!(Job, job.id).delegation
    grant = Repo.get!(Grant, grant_id)
    assert grant.status in ~w(revoked exhausted)
    assert (grant.usage["total_tokens"] || 0) > 0
  end

  test "an ordinary deep-work job cannot see or run the repository tools" do
    assert {:ok, conversation} = Conversations.ensure_conversation("coding-job-confined")

    assert {:ok, job} =
             Work.start_job(%{
               conversation_id: conversation.id,
               owner_visitor_id: conversation.visitor_id,
               surface: "text",
               goal: "[deep-work-job]",
               kind: "deep_work"
             })

    job = await_terminal_job(job.id)
    assert job.status == "completed"

    # No repository tool ever ran, and no grant was minted for it.
    steps = Work.list_job_steps(job)
    refute Enum.any?(steps, &String.starts_with?(&1.tool_name, "repo_"))

    assert Repo.aggregate(from(g in Grant, where: g.conversation_id == ^conversation.id), :count) ==
             0
  end
end
