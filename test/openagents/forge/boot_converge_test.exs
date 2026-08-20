defmodule OpenAgents.Forge.BootConvergeTest do
  @moduledoc """
  Boot convergence (#123): a node converges to the live fleet target's
  beams before serving, and every failure path degrades honestly to image
  code — no live target, missing artifact (replaced node), off-allowlist
  module — never a refusal to boot.
  """

  use OpenAgents.DataCase, async: false
  alias OpenAgents.Forge.ArtifactFixtures
  alias OpenAgents.Forge.BootConverge
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.Target
  alias OpenAgents.Repo

  setup do
    base = Path.join(System.tmp_dir!(), "boot-conv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "data/beams"))

    previous =
      for key <- [:forge_data_dir, :forge_wal_dir] do
        {key, Application.get_env(:openagents, key)}
      end

    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:openagents, key, value),
          else: Application.delete_env(:openagents, key)
      end

      File.rm_rf(base)
      :persistent_term.erase({BootConverge, :state})
    end)

    %{base: base}
  end

  # A unique repo name per test module: forge target rows can leak past the
  # sandbox from other tests' async deploy-lane writes.
  @repo "bootconv-test"

  defp insert_target!(status, details) do
    sha = String.duplicate("d", 40)

    %Target{}
    |> Target.changeset(%{repo: @repo, sha: sha, promoted_by: "operator:t", status: "promoted"})
    |> Repo.insert!()
    |> Ecto.Changeset.change(%{status: status, details: details})
    |> Repo.update!()
  end

  defp scratch_beam(module_name) do
    {:module, module, binary, _result} =
      Module.create(
        module_name,
        quote do
          def marker, do: :boot_converged
        end,
        Macro.Env.location(__ENV__)
      )

    :code.purge(module)
    :code.delete(module)
    {module, binary}
  end

  defp artifact(module, binary) do
    sha = String.duplicate("d", 40)
    built = ArtifactFixtures.create!(@repo, sha, [{to_string(module), binary}])

    %{
      built: built,
      details: %{
        "artifact" => "beams/#{built.digest}.tar",
        "artifact_digest" => built.digest,
        "build_id" => built.build_id,
        "modules" => Enum.map(built.beams, & &1.module)
      }
    }
  end

  test "converges to the live target's artifact and reports it" do
    {module, binary} = scratch_beam(OpenAgents.Scratch.BootConvergeProbe)

    artifact = artifact(module, binary)
    artifact_abs = Path.join(Repos.data_dir(), artifact.details["artifact"])
    File.write!(artifact_abs, artifact.built.bytes)
    insert_target!("live", artifact.details)

    outcome = BootConverge.converge(@repo)
    assert %{"state" => "converged", "modules" => 1} = outcome
    assert BootConverge.state()["state"] == "converged"
    assert module.marker() == :boot_converged

    :code.purge(module)
    :code.delete(module)
  end

  test "boots on image code, honestly, for every degraded path" do
    # No target at all.
    assert %{"state" => "image", "reason" => "no_target"} = BootConverge.converge(@repo)

    # A target that is not live.
    insert_target!("failed", %{})

    assert %{"state" => "image", "reason" => "target_not_live:failed"} =
             BootConverge.converge(@repo)

    # A live target whose artifact this node does not have (replaced node).
    {missing_module, missing_binary} = scratch_beam(OpenAgents.Scratch.BootConvergeMissing)
    missing = artifact(missing_module, missing_binary)
    insert_target!("live", missing.details)
    assert %{"state" => "image", "reason" => "artifact_missing"} = BootConverge.converge(@repo)

    # A live target with an off-allowlist module in the tar.
    {module, binary} = scratch_beam(OpenAgents.NotAllowed.BootConvergeOffLimits)
    off_limit = artifact(module, binary)
    artifact_abs = Path.join(Repos.data_dir(), off_limit.details["artifact"])
    File.write!(artifact_abs, off_limit.built.bytes)
    insert_target!("live", off_limit.details)

    assert %{"state" => "image", "reason" => "off_allowlist:" <> _rest} =
             BootConverge.converge(@repo)

    refute Code.ensure_loaded?(OpenAgents.NotAllowed.BootConvergeOffLimits)
  end

  test "a replaced node converges by fetching the artifact blob from the WAL store" do
    {module, binary} = scratch_beam(OpenAgents.Scratch.BootConvergeWalFetch)

    artifact = artifact(module, binary)

    {:ok, _key} =
      OpenAgents.Forge.WAL.put_artifact(@repo, artifact.built.digest, artifact.built.bytes)

    # The target names an artifact path that does NOT exist locally — the
    # blob store is the only copy, exactly a replaced node's situation.
    insert_target!("live", artifact.details)

    assert %{"state" => "converged", "modules" => 1} = BootConverge.converge(@repo)
    assert module.marker() == :boot_converged
    # The fetched blob is now local cache for next boot.
    assert File.exists?(Path.join(Repos.data_dir(), artifact.details["artifact"]))

    :code.purge(module)
    :code.delete(module)
  end

  test "a live no-op target (no artifact recorded) counts as converged" do
    insert_target!("live", %{})
    assert %{"state" => "converged", "modules" => 0} = BootConverge.converge(@repo)
  end
end
