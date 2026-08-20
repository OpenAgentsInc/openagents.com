defmodule OpenAgents.Forge.ReceiptReplayerTest do
  @moduledoc """
  F1 (#124, audit A7): push receipts are DERIVED from the WAL, exactly once
  by index position. A receipt lost between WAL persist and the Postgres
  insert (or to a database restore) is re-derived by the replayer; existing
  rows are never duplicated or rewritten; refs never live in Postgres.
  """

  use OpenAgents.SarahDataCase, async: false
  @moduletag :skip
  import Ecto.Query

  alias OpenAgents.Forge
  alias OpenAgents.Forge.{Pushes, PushReceipt, Repos}
  alias OpenAgents.Repo

  defmodule TestPipeline do
    @moduledoc false
    use Plug.Builder

    plug OpenAgentsWeb.Plugs.ForgeGitAuth
    plug OpenAgents.Forge.GitHTTP
  end

  @operator_token "forge_test_operator_token_0123456789"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "replayer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    previous =
      for key <- [:forge_data_dir, :forge_wal_dir] do
        {key, Application.get_env(:openagents, key)}
      end

    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    port = free_port()
    start_supervised!({Bandit, plug: TestPipeline, port: port, ip: {127, 0, 0, 1}})

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:openagents, key, value),
          else: Application.delete_env(:openagents, key)
      end

      File.rm_rf(base)
    end)

    %{base: base, url: "http://x:#{@operator_token}@127.0.0.1:#{port}/demo.git"}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp push_commit!(url, base, marker) do
    work = Path.join(base, "work-#{marker}")
    File.mkdir_p!(work)

    git = fn args ->
      {out, status} =
        System.cmd("git", ["-c", "credential.helper="] ++ args,
          cd: work,
          stderr_to_stdout: true,
          env: [{"GIT_TERMINAL_PROMPT", "0"}]
        )

      if status != 0, do: flunk("git #{Enum.join(args, " ")} failed: #{out}")
      out
    end

    unless File.dir?(Path.join(work, ".git")) do
      git.(["clone", url, "."])
    end

    File.write!(Path.join(work, "#{marker}.txt"), marker)
    git.(["add", "-A"])

    git.([
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "commit",
      "-m",
      marker,
      "--allow-empty"
    ])

    git.(["push", url, "HEAD:main"])
  end

  test "lost receipts are re-derived from the WAL, exactly once", %{base: base, url: url} do
    Repos.ensure_repo!("demo")
    push_commit!(url, base, "one")
    push_commit!(url, base, "two")

    assert [%{wal_seq: 1}, %{wal_seq: 0}] =
             Forge.recent_pushes("demo") |> Enum.map(&Map.take(&1, [:wal_seq]))

    original = Forge.recent_pushes("demo")

    # Simulate the crash-between-persist-and-insert (or a DB restore).
    Repo.delete_all(from(p in PushReceipt, where: p.repo == "demo" and p.wal_seq == 0))
    assert length(Forge.recent_pushes("demo")) == 1

    # The replayer re-derives exactly the missing receipt.
    assert Pushes.reconcile_receipts("demo") == 1
    replayed = Forge.recent_pushes("demo")
    assert length(replayed) == 2

    # The re-derived row carries the same ref transition and principal as
    # the original (duration is not reconstructible and is not identity).
    original_zero = Enum.find(original, &(&1.wal_seq == 0))
    replayed_zero = Enum.find(replayed, &(&1.wal_seq == 0))
    assert replayed_zero.refs == original_zero.refs
    assert replayed_zero.principal == original_zero.principal

    # Idempotent: nothing more to derive, nothing duplicated.
    assert Pushes.reconcile_receipts("demo") == 0
    assert length(Forge.recent_pushes("demo")) == 2
  end

  test "a repo with no WAL reconciles to zero, quietly" do
    assert Pushes.reconcile_receipts("demo") == 0
  end
end
