defmodule OpenAgents.Forge.VerificationTest do
  @moduledoc """
  EXIT-002, the part that only appears on a fleet: three nodes share one WAL
  and keep three separate projections of it, so at any moment they are at
  three different sequences.

  Every node here is a real bare repository built by real replay from a real
  WAL whose entries are genuine `receive-pack` requests. The nodes differ only
  in `:forge_data_dir`, which is exactly how they differ in production: the WAL
  is shared object storage and `/var/lib/openagents/forge/repos` is local disk.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.{Repos, Sync, Verification, WAL}

  defmodule TestPipeline do
    @moduledoc false
    use Plug.Builder

    plug OpenAgentsWeb.Plugs.ForgeGitAuth
    plug OpenAgents.Forge.GitHTTP
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base =
      Path.join(System.tmp_dir!(), "forge-verification-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)

    # One WAL, three data directories: the fleet's actual shape.
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))
    Application.put_env(:openagents, :forge_data_dir, node_dir(base, :one))
    OpenAgents.Forge.CacheReadiness.reset()

    user = OpenAgents.AccountsFixtures.repository_user_fixture("fleet-owner")

    {:ok, repository, :created} =
      OpenAgents.Repositories.create_user_repository(user, %{name: "demo"}, "fleet-demo")

    repository =
      repository
      |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
      |> OpenAgents.Repo.update!()

    {:ok, _api_token, plaintext} =
      OpenAgents.ApiTokens.create(user, %{
        name: "forge verification test",
        scopes: ["forge:write"],
        lifetime_days: 1
      })

    port = free_port()
    start_supervised!({Bandit, plug: TestPipeline, port: port, ip: {127, 0, 0, 1}})

    on_exit(fn ->
      Application.put_env(:openagents, :forge_data_dir, previous_data)
      Application.put_env(:openagents, :forge_wal_dir, previous_wal)
      OpenAgents.Forge.CacheReadiness.reset()
      File.rm_rf(base)
    end)

    %{
      base: base,
      repo: repository.storage_key,
      repository: repository,
      # `verify_cluster/2` asks its members concurrently, and in production each
      # member is a different machine with its own `:forge_data_dir`. Here they
      # are one VM sharing one application environment, so the stand-in for a
      # node runs through this agent, which serializes what distribution would
      # have separated.
      nodes: start_supervised!({Agent, fn -> :ok end}),
      url: "http://x:#{plaintext}@127.0.0.1:#{port}/fleet-owner/demo.git"
    }
  end

  describe "a node that has not replayed yet" do
    test "is reported as behind rather than as a disagreement", context do
      seed_history!(context)
      replay!(context, :two)

      # One more accepted push. Node one applied it; node two has not read the
      # log since, which is every node's ordinary state for the minute after a
      # push lands somewhere else.
      commit_and_push!(work_dir(context), "later.txt", "later\n", "later")

      assert {:ok, current} = at_node(context, :one, fn -> Verification.verify(context.repo) end)
      assert current.status == :current
      assert current.behind == 0

      assert {:ok, behind} = at_node(context, :two, fn -> Verification.verify(context.repo) end)
      assert behind.findings == []
      assert behind.status == :behind
      assert behind.behind == 1
      assert behind.position == current.position - 1
      assert behind.applied_seq == behind.position
      assert behind.head_seq == current.head_seq
    end

    test "names the node and the sequence its answer was computed at", context do
      seed_history!(context)
      replay!(context, :two)

      assert {:ok, report} = at_node(context, :two, fn -> Verification.verify(context.repo) end)
      assert report.node == node()
      assert report.applied_seq == report.head_seq
      assert report.position == report.head_seq
    end

    test "an empty projection is the same answer at sequence -1", context do
      seed_history!(context)

      assert {:ok, report} = at_node(context, :three, fn -> Verification.verify(context.repo) end)
      assert report.findings == []
      assert report.status == :behind
      assert report.position == -1
      assert report.applied_seq == -1
      assert report.behind == report.head_seq + 1
    end

    test "catches up to clean once it replays", context do
      seed_history!(context)

      assert {:ok, %{status: :behind}} =
               at_node(context, :two, fn -> Verification.verify(context.repo) end)

      replay!(context, :two)

      assert {:ok, %{status: :current, behind: 0, findings: []}} =
               at_node(context, :two, fn -> Verification.verify(context.repo) end)
    end
  end

  describe "a projection that contradicts the log" do
    test "a ref moved without a push is reported on a current node", context do
      seed_history!(context)
      path = at_node(context, :one, fn -> Repos.bare_path(context.repo) end)
      {parent, 0} = Repos.git(path, ["rev-parse", "refs/heads/main^"])
      {_output, 0} = Repos.git(path, ["update-ref", "refs/heads/main", String.trim(parent)])

      assert {:error, report} =
               at_node(context, :one, fn -> Verification.verify(context.repo) end)

      assert report.status == :diverged
      assert %{"ref" => "refs/heads/main"} = detail(report.findings, "served_refs_diverged")
    end

    test "a ref moved without a push is reported on a node that is also behind", context do
      seed_history!(context)
      replay!(context, :two)
      commit_and_push!(work_dir(context), "later.txt", "later\n", "later")

      # Node two is a legitimate entry behind *and* someone moved a ref on its
      # disk. Lag must not launder the second fact.
      path = at_node(context, :two, fn -> Repos.bare_path(context.repo) end)
      {parent, 0} = Repos.git(path, ["rev-parse", "refs/heads/main^"])
      {_output, 0} = Repos.git(path, ["update-ref", "refs/heads/main", String.trim(parent)])

      assert {:error, report} =
               at_node(context, :two, fn -> Verification.verify(context.repo) end)

      assert report.status == :diverged
      assert %{"ref" => "refs/heads/main"} = detail(report.findings, "served_refs_diverged")
    end

    test "a ref the log never recorded is reported however far behind the node is", context do
      seed_history!(context)
      replay!(context, :two)
      commit_and_push!(work_dir(context), "later.txt", "later\n", "later")

      path = at_node(context, :two, fn -> Repos.bare_path(context.repo) end)
      {head, 0} = Repos.git(path, ["rev-parse", "refs/heads/main"])
      {_output, 0} = Repos.git(path, ["update-ref", "refs/heads/smuggled", String.trim(head)])

      assert {:error, report} =
               at_node(context, :two, fn -> Verification.verify(context.repo) end)

      assert %{"ref" => "refs/heads/smuggled", "recorded" => nil} =
               detail(report.findings, "served_refs_diverged")
    end

    test "an object an applied entry introduced cannot be missing", context do
      seed_history!(context)
      path = at_node(context, :one, fn -> Repos.bare_path(context.repo) end)
      {head, 0} = Repos.git(path, ["rev-parse", "refs/heads/feature"])
      head = String.trim(head)

      File.rm_rf!(Path.join([path, "objects", String.slice(head, 0, 2)]))
      {_output, 0} = Repos.git(path, ["update-ref", "-d", "refs/heads/feature"])

      assert {:error, report} =
               at_node(context, :one, fn -> Verification.verify(context.repo) end)

      assert %{"object" => ^head} = detail(report.findings, "object_missing")
    end

    test "a marker naming a sequence the log does not have is reported", context do
      seed_history!(context)
      path = at_node(context, :one, fn -> Repos.bare_path(context.repo) end)
      Repos.record_applied_seq_at!(path, 99)

      assert {:error, report} =
               at_node(context, :one, fn -> Verification.verify(context.repo) end)

      assert %{"applied_seq" => 99} = detail(report.findings, "applied_seq_beyond_log")
    end

    test "a marker rolled forward does not silence a stale projection", context do
      seed_history!(context)
      replay!(context, :two)
      commit_and_push!(work_dir(context), "later.txt", "later\n", "later")

      # The marker is the projection's own claim about itself. Claiming to have
      # applied the head does not make the head's refs appear.
      path = at_node(context, :two, fn -> Repos.bare_path(context.repo) end)
      {:ok, _generation, index} = at_node(context, :two, fn -> WAL.read_index(context.repo) end)
      Repos.record_applied_seq_at!(path, WAL.next_seq(index) - 1)

      assert {:error, report} =
               at_node(context, :two, fn -> Verification.verify(context.repo) end)

      assert detail(report.findings, "served_refs_diverged") != nil
    end
  end

  describe "the whole fleet at once" do
    test "three nodes at three sequences converge rather than disagree", context do
      seed_history!(context)
      replay!(context, :two)
      replay!(context, :three)
      commit_and_push!(work_dir(context), "one-later.txt", "one\n", "one later")
      replay!(context, :two)
      commit_and_push!(work_dir(context), "two-later.txt", "two\n", "two later")

      assert {:ok, cluster} = verify_cluster(context)
      assert cluster.status == :converging
      assert cluster.findings == []
      assert Enum.map(cluster.nodes, & &1.behind) == [0, 1, 2]
      assert Enum.map(cluster.nodes, & &1.status) == [:current, :behind, :behind]
      assert Enum.uniq(Enum.map(cluster.nodes, & &1.head_seq)) == [cluster.head_seq]
      assert cluster.log_agreement == :agreed
    end

    test "a fleet that has finished replaying is verified", context do
      seed_history!(context)
      replay!(context, :two)
      replay!(context, :three)

      assert {:ok, cluster} = verify_cluster(context)
      assert cluster.status == :verified
      assert Enum.all?(cluster.nodes, &(&1.status == :current))
    end

    test "one node's tampering is the fleet's answer, and it names the node", context do
      seed_history!(context)
      replay!(context, :two)
      replay!(context, :three)

      path = at_node(context, :three, fn -> Repos.bare_path(context.repo) end)
      {head, 0} = Repos.git(path, ["rev-parse", "refs/heads/main"])
      {_output, 0} = Repos.git(path, ["update-ref", "refs/heads/smuggled", String.trim(head)])

      assert {:error, cluster} = verify_cluster(context)
      assert cluster.status == :diverged
      assert [%{node: :three, code: "served_refs_diverged"}] = cluster.findings
      assert Enum.map(cluster.nodes, & &1.status) == [:current, :current, :diverged]
    end

    test "a node that does not answer leaves the fleet converging, not verified", context do
      seed_history!(context)
      replay!(context, :two)
      replay!(context, :three)

      rpc = fn
        :three, _module, _function, _args, _timeout ->
          exit(:noconnection)

        member, module, function, args, _timeout ->
          apply_at(context, member, module, function, args)
      end

      assert {:ok, cluster} = verify_cluster(context, rpc: rpc)
      assert cluster.status == :converging
      assert cluster.findings == []
      assert %{node: :three, status: :unreachable} = List.last(cluster.nodes)
    end

    test "no node answering is not a clean fleet", context do
      seed_history!(context)

      rpc = fn _member, _module, _function, _args, _timeout -> exit(:noconnection) end

      assert {:error, cluster} = verify_cluster(context, rpc: rpc)
      assert cluster.status == :unavailable
    end
  end

  ## ── helpers ────────────────────────────────────────────────────────────

  # Three nodes, one WAL. `:erpc` is replaced by a call that runs the same
  # verification against the named node's own data directory, which is the one
  # thing that actually differs between fleet members.
  defp verify_cluster(context, options \\ []) do
    rpc =
      Keyword.get(options, :rpc, fn member, module, function, args, _timeout ->
        apply_at(context, member, module, function, args)
      end)

    Verification.verify_cluster(context.repo, members: fn -> [:one, :two, :three] end, rpc: rpc)
  end

  defp apply_at(context, member, module, function, args) do
    Agent.get(
      context.nodes,
      fn _state -> at_node(context, member, fn -> apply(module, function, args) end) end,
      30_000
    )
  end

  defp at_node(context, member, function) do
    previous = Application.get_env(:openagents, :forge_data_dir)
    Application.put_env(:openagents, :forge_data_dir, node_dir(context.base, member))

    try do
      function.()
    after
      Application.put_env(:openagents, :forge_data_dir, previous)
    end
  end

  defp node_dir(base, member), do: Path.join(base, "data-#{member}")

  defp replay!(context, member) do
    assert :ok = at_node(context, member, fn -> Sync.ensure_fresh(context.repo) end)
  end

  defp detail(findings, code) do
    Enum.find_value(findings, fn
      %{code: ^code, detail: detail} -> detail
      _other -> nil
    end)
  end

  defp work_dir(context), do: Path.join(context.base, "work")

  defp seed_history!(context) do
    work = work_dir(context)

    unless File.exists?(work) do
      sh!(context.base, "git", ["clone", context.url, work])
      sh!(work, "git", ["config", "user.email", "test@example.com"])
      sh!(work, "git", ["config", "user.name", "Forge Test"])
      commit_and_push!(work, "one.txt", "one\n", "one")
      commit_and_push!(work, "two.txt", "two\n", "two")
      sh!(work, "git", ["checkout", "-b", "feature"])
      commit_and_push!(work, "feature.txt", "feature\n", "feature", "feature")
      sh!(work, "git", ["checkout", "main"])
    end

    :ok
  end

  defp commit_and_push!(work, filename, contents, message, branch \\ "main") do
    File.write!(Path.join(work, filename), contents)
    sh!(work, "git", ["add", "."])
    sh!(work, "git", ["commit", "-m", message])
    sh!(work, "git", ["push", "origin", "HEAD:#{branch}"])
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp sh!(dir, "git", args), do: sh_raw!(dir, "git", ["-c", "credential.helper="] ++ args)
  defp sh!(dir, command, args), do: sh_raw!(dir, command, args)

  defp sh_raw!(dir, command, args) do
    {output, status} = System.cmd(command, args, cd: dir, stderr_to_stdout: true)
    if status != 0, do: flunk("#{command} #{Enum.join(args, " ")} failed:\n#{output}")
    output
  end
end
