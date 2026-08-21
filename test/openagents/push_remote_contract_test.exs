defmodule OpenAgents.PushRemoteContractTest do
  use ExUnit.Case, async: true

  @script "ops/ci/push-remote-check.sh"

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
