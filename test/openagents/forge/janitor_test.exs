defmodule OpenAgents.Forge.JanitorTest do
  @moduledoc "Cache retention (#123): stale clones and non-live artifacts are pruned; truth never is."

  use OpenAgents.SarahDataCase, async: false
  @moduletag :skip
  alias OpenAgents.Forge.Janitor
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.Target
  alias OpenAgents.Repo

  setup do
    base = Path.join(System.tmp_dir!(), "janitor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "data/beams"))
    File.mkdir_p!(Path.join(base, "jobs"))

    previous =
      for key <- [:forge_data_dir, :coding_jobs_dir] do
        {key, Application.get_env(:openagents, key)}
      end

    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :coding_jobs_dir, Path.join(base, "jobs"))

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:openagents, key, value),
          else: Application.delete_env(:openagents, key)
      end

      File.rm_rf(base)
    end)

    %{base: base}
  end

  test "prunes stale job clones and stale non-live artifacts, keeps the live one", %{base: base} do
    # Two artifacts: one is the live target's, one is stale junk.
    live_sha = String.duplicate("e", 40)
    File.write!(Path.join(base, "data/beams/#{live_sha}.tar"), "live")
    File.write!(Path.join(base, "data/beams/oldjunk.tar"), "junk")

    %Target{}
    |> Target.changeset(%{repo: "sarah", sha: live_sha, promoted_by: "op:t", status: "promoted"})
    |> Repo.insert!()
    |> Ecto.Changeset.change(%{
      status: "live",
      details: %{"artifact" => "beams/#{live_sha}.tar"}
    })
    |> Repo.update!()

    # One stale clone for a job that does not exist (terminal/unknown).
    stale_clone = Path.join(base, "jobs/job-11111111-2222-3333-4444-555555555555")
    File.mkdir_p!(stale_clone)

    # Sweep "one week from now": everything present is older than retention.
    future = System.system_time(:millisecond) + 7 * 24 * 60 * 60 * 1000
    assert {1, 1} = Janitor.sweep(future)

    refute File.exists?(stale_clone)
    refute File.exists?(Path.join(base, "data/beams/oldjunk.tar"))
    # The live target's artifact survives any age (boot convergence needs it).
    assert File.exists?(Path.join(base, "data/beams/#{live_sha}.tar"))
    # Truth is never expired.
    assert File.exists?(Repos.data_dir())
  end

  test "a fresh clone is not pruned" do
    fresh =
      Path.join(
        OpenAgents.Tools.Repository.jobs_dir(),
        "job-99999999-2222-3333-4444-555555555555"
      )

    File.mkdir_p!(fresh)
    assert {0, 0} = Janitor.sweep()
    assert File.exists?(fresh)
  end
end
