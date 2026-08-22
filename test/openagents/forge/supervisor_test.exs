defmodule OpenAgents.Forge.SupervisorTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Forge.{Builder, MirrorWatch, Supervisor}

  test "starts mirror drift repair while the deploy lane is fenced" do
    previous = Application.get_env(:openagents, :forge_deploy_lane_enabled)
    Application.put_env(:openagents, :forge_deploy_lane_enabled, false)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:openagents, :forge_deploy_lane_enabled)
      else
        Application.put_env(:openagents, :forge_deploy_lane_enabled, previous)
      end
    end)

    assert {:ok, {_flags, child_specs}} = Supervisor.init([])
    assert Enum.any?(child_specs, &(&1.id == MirrorWatch))
    refute Enum.any?(child_specs, &(&1.id == Builder))
  end
end
