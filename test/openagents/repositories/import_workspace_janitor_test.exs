defmodule OpenAgents.Repositories.ImportWorkspaceJanitorTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Repositories.ImportWorkspaceJanitor

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "repository-import-janitor-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    previous_root = Application.get_env(:openagents, :repository_import_temp_dir)

    previous_retention =
      Application.get_env(:openagents, :repository_import_workspace_retention_ms)

    Application.put_env(:openagents, :repository_import_temp_dir, root)
    Application.put_env(:openagents, :repository_import_workspace_retention_ms, 1_000)

    on_exit(fn ->
      restore_env(:repository_import_temp_dir, previous_root)
      restore_env(:repository_import_workspace_retention_ms, previous_retention)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "removes only stale import workspaces and bounds each sweep", %{root: root} do
    stale = import_workspace(root, Ecto.UUID.generate(), 1)
    fresh = import_workspace(root, Ecto.UUID.generate(), 2)
    unrelated = Path.join(root, "keep-me")
    File.mkdir_p!(stale)
    File.mkdir_p!(fresh)
    File.mkdir_p!(unrelated)

    future = System.system_time(:millisecond) + 2_000
    assert ImportWorkspaceJanitor.sweep(future) == 2
    refute File.exists?(stale)
    refute File.exists?(fresh)
    assert File.exists?(unrelated)

    Enum.each(1..101, fn number ->
      File.mkdir_p!(import_workspace(root, Ecto.UUID.generate(), number + 10))
    end)

    assert ImportWorkspaceJanitor.sweep(future) == 100
    assert length(File.ls!(root)) == 2
  end

  defp import_workspace(root, id, suffix),
    do: Path.join(root, "openagents-import-#{id}-#{suffix}")

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
