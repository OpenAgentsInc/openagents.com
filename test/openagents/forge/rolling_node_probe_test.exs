defmodule OpenAgents.Forge.RollingNodeProbeTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.BootConverge
  alias OpenAgents.Forge.RollingNodeProbe

  setup do
    previous_boot = :persistent_term.get({BootConverge, :state}, :missing)
    previous_digest = Application.get_env(:openagents, :image_digest)
    digest = "sha256:" <> String.duplicate("f", 64)

    Application.put_env(:openagents, :image_digest, digest)

    :persistent_term.put(
      {BootConverge, :state},
      %{
        "schema" => "openagents.forge.boot-convergence.v2",
        "state" => "degraded",
        "ready" => false,
        "reason" => "previous_live_target",
        "sha" => OpenAgents.BuildInfo.revision(),
        "artifact_digest" => nil,
        "manifest_digest" => nil,
        "modules" => 0,
        "attempts" => 1,
        "retry_in_ms" => nil
      }
    )

    on_exit(fn ->
      restore_boot(previous_boot)
      restore_env(:image_digest, previous_digest)
    end)

    %{digest: digest}
  end

  test "accepts the exact rolling image while boot convergence references the previous target", %{
    digest: digest
  } do
    assert %{
             ready: true,
             boot_converged: true,
             database_ready: true,
             sha: revision,
             image_digest: ^digest
           } = RollingNodeProbe.status(1, OpenAgents.BuildInfo.revision(), digest)

    assert revision == OpenAgents.BuildInfo.revision()
  end

  test "rejects a rolling image digest mismatch", %{digest: digest} do
    refute RollingNodeProbe.status(
             1,
             OpenAgents.BuildInfo.revision(),
             String.replace_suffix(digest, "f", "e")
           ).ready
  end

  defp restore_boot(:missing), do: :persistent_term.erase({BootConverge, :state})
  defp restore_boot(state), do: :persistent_term.put({BootConverge, :state}, state)

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
