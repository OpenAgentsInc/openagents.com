defmodule OpenAgents.Forge.ReposTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Forge.Repos

  test "a structurally invalid cache is quarantined and reinitialized" do
    path =
      Path.join(
        System.tmp_dir!(),
        "forge-repos-#{System.unique_integer([:positive, :monotonic])}.git"
      )

    on_exit(fn ->
      File.rm_rf!(path)
      Enum.each(Path.wildcard(path <> ".corrupt-*"), &File.rm_rf!/1)
    end)

    assert ^path = Repos.ensure_repo_at!(path)

    # Simulate the production failure: HEAD survives but the refs directory
    # is lost, so git refuses the directory as a repository.
    File.rm_rf!(Path.join(path, "refs"))
    assert {_output, 128} = Repos.git(path, ["rev-parse", "--is-bare-repository"])

    assert ^path = Repos.ensure_repo_at!(path)
    assert {"true" <> _rest, 0} = Repos.git(path, ["rev-parse", "--is-bare-repository"])
    assert [_quarantined] = Path.wildcard(path <> ".corrupt-*")
  end
end
