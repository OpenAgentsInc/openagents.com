defmodule OpenAgents.PushRemoteContractTest do
  use ExUnit.Case, async: true

  @script "ops/ci/push-remote-check.sh"
  @installer "ops/dev/install-push-guard.sh"

  defp check(arguments, environment \\ []) do
    System.cmd("sh", [@script | arguments], env: environment, stderr_to_stdout: true)
  end

  test "a GitHub remote is refused, whatever its URL form" do
    for url <- [
          "git@github.com:OpenAgentsInc/openagents.com.git",
          "https://github.com/OpenAgentsInc/openagents.com.git",
          "ssh://git@github.com/OpenAgentsInc/openagents.com.git"
        ] do
      assert {output, 1} = check(["origin", url])
      assert output =~ "Refusing to push"
      assert output =~ "git push openagents HEAD:main"
    end
  end

  test "the forge is admitted over HTTPS and SSH" do
    for url <- [
          "https://openagents.com/OpenAgentsInc/openagents.com.git",
          "https://staging.openagents.com/OpenAgentsInc/openagents.com.git",
          "git@openagents.com:OpenAgentsInc/openagents.com.git"
        ] do
      assert {_output, 0} = check(["openagents", url])
    end
  end

  # A host that merely ends in the forge's name is a different host.
  test "a lookalike host is refused" do
    assert {_output, 1} = check(["origin", "https://openagents.com.example.net/x.git"])
  end

  test "the override admits one push and says so" do
    assert {output, 0} =
             check(
               ["origin", "git@github.com:OpenAgentsInc/openagents.com.git"],
               [{"OPENAGENTS_ALLOW_NON_FORGE_PUSH", "1"}]
             )

    assert output =~ "push_remote_override"
  end

  test "the installer leaves a clone refusing GitHub" do
    root = Path.join(System.tmp_dir!(), "push-guard-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(root, "ops/ci"))
    File.mkdir_p!(Path.join(root, "ops/dev"))
    File.cp!(@script, Path.join(root, @script))
    File.cp!(@installer, Path.join(root, @installer))
    {_output, 0} = System.cmd("git", ["init", "-q", root])

    assert {_output, 0} = System.cmd("sh", [@installer], cd: root, stderr_to_stdout: true)

    hook = Path.join(root, ".git/hooks/pre-push")
    assert File.exists?(hook)

    # The guard travels with the hook, so a worktree on a branch that predates
    # it still refuses the wrong remote instead of failing to find a file.
    assert File.exists?(Path.join(root, ".git/hooks/openagents-push-remote-check.sh"))
    File.rm!(Path.join(root, @script))

    assert {output, 1} =
             System.cmd("sh", [hook, "origin", "git@github.com:OpenAgentsInc/x.git"],
               cd: root,
               stderr_to_stdout: true
             )

    assert output =~ "Refusing to push"

    # The guard alone: a clone that installs it must not inherit the release
    # gate, which needs a disposable database and minutes of wall clock.
    refute File.read!(hook) =~ "gate.sh"
  end

  test "the installer refuses to overwrite a hook it does not recognize" do
    root = Path.join(System.tmp_dir!(), "push-guard-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(root, "ops/ci"))
    File.mkdir_p!(Path.join(root, "ops/dev"))
    File.cp!(@script, Path.join(root, @script))
    File.cp!(@installer, Path.join(root, @installer))
    {_output, 0} = System.cmd("git", ["init", "-q", root])

    hook = Path.join(root, ".git/hooks/pre-push")
    File.write!(hook, "#!/bin/sh\nexit 0\n")

    assert {output, 1} = System.cmd("sh", [@installer], cd: root, stderr_to_stdout: true)
    assert output =~ "--force"
    assert File.read!(hook) == "#!/bin/sh\nexit 0\n"

    assert {_output, 0} =
             System.cmd("sh", [@installer, "--force"], cd: root, stderr_to_stdout: true)

    assert File.read!(hook) =~ "openagents-push-guard"
  end

  test "--ensure installs quietly and never fails the build" do
    root = Path.join(System.tmp_dir!(), "push-guard-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(root, "ops/ci"))
    File.mkdir_p!(Path.join(root, "ops/dev"))
    File.cp!(@script, Path.join(root, @script))
    File.cp!(@installer, Path.join(root, @installer))
    {_output, 0} = System.cmd("git", ["init", "-q", root])

    assert {"", 0} = System.cmd("sh", [@installer, "--ensure"], cd: root, stderr_to_stdout: true)
    assert File.read!(Path.join(root, ".git/hooks/pre-push")) =~ "openagents-push-guard"

    # A hook someone else installed is a decision, not an obstacle: say so and
    # let precommit continue.
    File.write!(Path.join(root, ".git/hooks/pre-push"), "#!/bin/sh\nexit 0\n")

    assert {output, 0} =
             System.cmd("sh", [@installer, "--ensure"], cd: root, stderr_to_stdout: true)

    assert output =~ "not the push guard"
    assert File.read!(Path.join(root, ".git/hooks/pre-push")) == "#!/bin/sh\nexit 0\n"
  end

  test "the pre-push hook runs the check before the release gate" do
    hook = File.read!(".githooks/pre-push")

    assert hook =~ "ops/ci/push-remote-check.sh"
    assert hook =~ "ops/ci/gate.sh"

    [check_at, gate_at] =
      for marker <- ["push-remote-check.sh", "gate.sh"] do
        hook |> String.split(marker) |> hd() |> String.length()
      end

    assert check_at < gate_at
  end
end
