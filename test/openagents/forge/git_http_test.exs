defmodule OpenAgents.Forge.GitHTTPTest do
  @moduledoc """
  End-to-end forge tests with the real git client over real HTTP: clone,
  push, WAL persistence, receipt derivation, re-materialization from the
  WAL after cache loss, and auth refusals. This is the P1 exit test from
  the roadmap, minus the fleet.
  """

  use OpenAgents.SarahDataCase, async: false
  alias OpenAgents.Forge
  alias OpenAgents.Forge.{Repos, WAL}

  defmodule TestPipeline do
    @moduledoc false
    use Plug.Builder

    plug OpenAgentsWeb.Plugs.ForgeGitAuth
    plug OpenAgents.Forge.GitHTTP
  end

  @operator_token "forge_test_operator_token_0123456789"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "forge-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    port = free_port()
    start_supervised!({Bandit, plug: TestPipeline, port: port, ip: {127, 0, 0, 1}})

    on_exit(fn ->
      Application.put_env(:openagents, :forge_data_dir, previous_data)
      Application.put_env(:openagents, :forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    %{base: base, port: port, url: "http://x:#{@operator_token}@127.0.0.1:#{port}/demo.git"}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # Every git call disables credential helpers so the developer keychain can
  # neither pollute these tests nor be polluted by them.
  defp sh!(dir, "git", args), do: sh_raw!(dir, "git", ["-c", "credential.helper="] ++ args)
  defp sh!(dir, command, args), do: sh_raw!(dir, command, args)

  defp sh_raw!(dir, command, args) do
    {output, status} = System.cmd(command, args, cd: dir, stderr_to_stdout: true)
    if status != 0, do: flunk("#{command} #{Enum.join(args, " ")} failed:\n#{output}")
    output
  end

  defp seed_clone!(base, url) do
    work = Path.join(base, "clone-#{System.unique_integer([:positive])}")
    sh!(base, "git", ["clone", url, work])
    sh!(work, "git", ["config", "user.email", "test@example.com"])
    sh!(work, "git", ["config", "user.name", "Forge Test"])
    work
  end

  defp commit_and_push!(work, filename, contents, message) do
    File.write!(Path.join(work, filename), contents)
    sh!(work, "git", ["add", "."])
    sh!(work, "git", ["commit", "-m", message])
    sh!(work, "git", ["push", "origin", "HEAD:main"])
  end

  test "clone, push, WAL persist, receipt, and PubSub — the ack chain", %{base: base, url: url} do
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, "forge:pushes")

    work = seed_clone!(base, url)
    commit_and_push!(work, "hello.txt", "hello forge\n", "first commit")

    # WAL is the authority: index has the entry and the ref.
    assert {:ok, _generation, index} = WAL.read_index("demo")
    assert [entry] = WAL.entries(index)
    assert entry["seq"] == 0
    assert entry["principal"] == "operator:forge-token"
    assert %{"refs/heads/main" => sha} = WAL.refs(index)
    assert byte_size(sha) == 40

    # Derived receipt exists, idempotent by (repo, wal_seq).
    assert [receipt] = Forge.recent_pushes("demo")
    assert receipt.wal_seq == 0
    assert receipt.refs["refs/heads/main"]["new"] == sha
    assert receipt.refs["refs/heads/main"]["old"] == nil

    # Deploy signal fired.
    assert_receive {:forge_push, %{repo: "demo", wal_seq: 0}}, 2_000

    # A second clone sees the commit.
    verify = seed_clone!(base, url)
    assert File.read!(Path.join(verify, "hello.txt")) == "hello forge\n"
  end

  test "a second push appends to the WAL and receipts stay ordered", %{base: base, url: url} do
    work = seed_clone!(base, url)
    commit_and_push!(work, "a.txt", "one\n", "one")
    commit_and_push!(work, "b.txt", "two\n", "two")

    assert {:ok, _generation, index} = WAL.read_index("demo")
    assert length(WAL.entries(index)) == 2
    assert [%{wal_seq: 1}, %{wal_seq: 0}] = Forge.recent_pushes("demo")
  end

  test "cache loss: the bare repo re-materializes from the WAL", %{base: base, url: url} do
    work = seed_clone!(base, url)
    commit_and_push!(work, "keep.txt", "durable\n", "durable commit")
    refs_before = Repos.refs("demo")

    # Kill the cache entirely.
    File.rm_rf!(Repos.bare_path("demo"))
    refute File.exists?(Repos.bare_path("demo"))

    # A fresh clone triggers materialization and sees identical state.
    verify = seed_clone!(base, url)
    assert File.read!(Path.join(verify, "keep.txt")) == "durable\n"
    assert Repos.refs("demo") == refs_before
  end

  test "unauthenticated and wrong-token pushes are refused", %{base: base, port: port, url: url} do
    work = seed_clone!(base, url)
    File.write!(Path.join(work, "no.txt"), "no\n")
    sh!(work, "git", ["add", "."])
    sh!(work, "git", ["commit", "-m", "unauthorized"])

    for bad_url <- [
          "http://127.0.0.1:#{port}/demo.git",
          "http://x:wrong-token@127.0.0.1:#{port}/demo.git"
        ] do
      {output, status} =
        System.cmd("git", ["-c", "credential.helper=", "push", bad_url, "HEAD:main"],
          cd: work,
          stderr_to_stdout: true,
          env: [{"GIT_TERMINAL_PROMPT", "0"}]
        )

      assert status != 0

      assert output =~ "401" or output =~ "Authentication" or
               output =~ "terminal prompts disabled"
    end

    # Nothing leaked into the WAL.
    case WAL.read_index("demo") do
      {:error, :not_found} -> :ok
      {:ok, _generation, index} -> assert WAL.entries(index) == []
    end
  end

  test "unknown repositories are refused", %{port: port} do
    {output, status} =
      System.cmd(
        "git",
        [
          "-c",
          "credential.helper=",
          "clone",
          "http://x:#{@operator_token}@127.0.0.1:#{port}/not-allowed.git"
        ],
        cd: System.tmp_dir!(),
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "404" or output =~ "not found" or output =~ "unknown"
  end

  test "a failed WAL persist rolls refs back and the push is not acked", %{base: base, url: url} do
    work = seed_clone!(base, url)
    commit_and_push!(work, "ok.txt", "fine\n", "fine")
    refs_before = Repos.refs("demo")

    # Break the WAL (unwritable dir) — the next push must not ack.
    wal_dir = Application.get_env(:openagents, :forge_wal_dir)
    File.chmod!(Path.join(wal_dir, "demo"), 0o500)

    File.write!(Path.join(work, "lost.txt"), "must not land\n")
    sh!(work, "git", ["add", "."])
    sh!(work, "git", ["commit", "-m", "must not land"])

    {output, status} =
      System.cmd("git", ["-c", "credential.helper=", "push", "origin", "HEAD:main"],
        cd: work,
        stderr_to_stdout: true
      )

    File.chmod!(Path.join(wal_dir, "demo"), 0o700)

    assert status != 0, "push must fail when the WAL cannot persist: #{output}"
    # Local refs rolled back — cache never ahead of authority.
    assert Repos.refs("demo") == refs_before
    assert {:ok, _generation, index} = WAL.read_index("demo")
    assert length(WAL.entries(index)) == 1
  end
end
