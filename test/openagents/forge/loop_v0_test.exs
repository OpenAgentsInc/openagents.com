defmodule OpenAgents.Forge.LoopV0Test do
  @moduledoc """
  The roadmap P4 exit test, automated: the full deploy loop with a real git
  push over real HTTP — push → promote → build → hot-load → live — with the
  push→live duration recorded in the deploy receipt. No Docker, no GitHub,
  anywhere in the loop. (The fleet run of this same loop is the post-P4
  rolling-replace verification; this is the loop itself.)
  """

  use OpenAgents.SarahDataCase, async: false
  alias OpenAgents.Forge.{FakeBuildExecutor, Targets}

  defmodule TestPipeline do
    @moduledoc false
    use Plug.Builder

    plug OpenAgentsWeb.Plugs.ForgeGitAuth
    plug OpenAgents.Forge.GitHTTP
  end

  @operator_token "forge_test_operator_token_0123456789"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "loop-v0-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    previous = %{
      data: Application.get_env(:openagents, :forge_data_dir),
      wal: Application.get_env(:openagents, :forge_wal_dir),
      executor: Application.get_env(:openagents, :forge_build_executor),
      allowlist: Application.get_env(:openagents, :forge_hot_load_allowlist)
    }

    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))
    Application.put_env(:openagents, :forge_build_executor, FakeBuildExecutor)

    port = free_port()
    start_supervised!({Bandit, plug: TestPipeline, port: port, ip: {127, 0, 0, 1}})
    start_supervised!({OpenAgents.Forge.Builder, []})
    start_supervised!({OpenAgents.Forge.HotLoader, []})

    on_exit(fn ->
      restore(:forge_data_dir, previous.data)
      restore(:forge_wal_dir, previous.wal)
      restore(:forge_build_executor, previous.executor)
      restore(:forge_hot_load_allowlist, previous.allowlist)
      File.rm_rf(base)
    end)

    %{base: base, url: "http://x:#{@operator_token}@127.0.0.1:#{port}/sarah.git"}
  end

  # Restoring a nil via put_env stores literal nil, which then shadows
  # get_env defaults ("Enumerable not implemented for Atom" class of flake);
  # an absent previous value must be restored by deleting the key.
  defp restore(key, nil), do: Application.delete_env(:openagents, key)
  defp restore(key, value), do: Application.put_env(:openagents, key, value)

  defp purge!(mod) do
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp sh!(dir, args) do
    {output, status} =
      System.cmd("git", ["-c", "credential.helper="] ++ args, cd: dir, stderr_to_stdout: true)

    if status != 0, do: flunk("git #{Enum.join(args, " ")} failed:\n#{output}")
    output
  end

  test "push → promote → build → hot-load → live, loop time receipted", %{base: base, url: url} do
    # A unique demo module per run so hot-loading is observable and clean.
    module_name = "OpenAgents.Scratch.LoopDemo#{System.unique_integer([:positive])}"
    Application.put_env(:openagents, :forge_hot_load_allowlist, ["OpenAgents.Scratch."])

    # The fake executor compiles this REAL source into loadable beams,
    # standing in for the sidecar's `mix compile` of the pushed tree.
    source = """
    defmodule #{module_name} do
      def revision, do: "loop-v0"
    end
    """

    Application.put_env(:openagents, :fake_build_result, FakeBuildExecutor.result_for(source))
    # result_for compiled (and loaded) the module to produce the beam; purge
    # it so only a real hot-load can make revision/0 callable below.
    purge!(Module.concat([module_name]))

    # 1. Push (real git, real HTTP, WAL-acked).
    work = Path.join(base, "clone")
    sh!(base, ["clone", url, work])
    sh!(work, ["config", "user.email", "loop@test"])
    sh!(work, ["config", "user.name", "Loop"])
    File.write!(Path.join(work, "demo.ex"), source)
    sh!(work, ["add", "."])
    sh!(work, ["commit", "-m", "loop v0 demo"])
    sh!(work, ["push", "origin", "HEAD:main"])

    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: work)
    sha = String.trim(sha)

    # 2. Promote (the operator approval).
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, "forge:deploys")
    assert {:ok, target} = Targets.promote("sarah", sha, "operator:loop-test")

    # 3–4. Build + hot-load run off the PubSub signals; wait for live.
    assert_receive {:forge_deploy, %{repo: "sarah", sha: ^sha, result: "live"}}, 10_000

    # The module is actually live in this runtime.
    module = Module.concat([module_name])
    assert module.revision() == "loop-v0"

    # Target walked the full lifecycle.
    assert Targets.current("sarah").status == "live"
    assert Targets.current("sarah").id == target.id

    # The loop time is first-class: measured from the push receipt.
    assert [deploy] = OpenAgents.Forge.recent_deploys("sarah")
    assert deploy.result == "live"
    assert is_integer(deploy.push_to_live_ms) and deploy.push_to_live_ms >= 0
    assert deploy.sha == sha
  end

  test "an off-allowlist build is honestly needs_rolling_replace, nothing loads", %{
    base: base,
    url: url
  } do
    Application.put_env(:openagents, :forge_hot_load_allowlist, ["OpenAgents.Scratch."])

    module_name = "OpenAgents.Turns.Forbidden#{System.unique_integer([:positive])}"

    source = """
    defmodule #{module_name} do
      def revision, do: "never"
    end
    """

    Application.put_env(:openagents, :fake_build_result, FakeBuildExecutor.result_for(source))
    purge!(Module.concat([module_name]))

    work = Path.join(base, "clone2")
    sh!(base, ["clone", url, work])
    sh!(work, ["config", "user.email", "loop@test"])
    sh!(work, ["config", "user.name", "Loop"])
    File.write!(Path.join(work, "f.ex"), source)
    sh!(work, ["add", "."])
    sh!(work, ["commit", "-m", "forbidden"])
    sh!(work, ["push", "origin", "HEAD:main"])
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: work)
    sha = String.trim(sha)

    Phoenix.PubSub.subscribe(OpenAgents.PubSub, "forge:deploys")
    {:ok, target} = Targets.promote("sarah", sha, "operator:loop-test")

    assert_receive {:forge_deploy, %{sha: ^sha, result: "needs_rolling_replace"}}, 10_000
    refute Code.ensure_loaded?(Module.concat([module_name]))
    assert Targets.current("sarah").id == target.id
    assert Targets.current("sarah").status == "needs_rolling_replace"
  end
end
