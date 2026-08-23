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
  alias OpenAgents.Forge.DeploymentNode
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

    previous_node_state = :sys.get_state(DeploymentNode)
    previous_persisted = :persistent_term.get({DeploymentNode, :state}, :missing)
    :persistent_term.erase({DeploymentNode, :state})

    :sys.replace_state(DeploymentNode, fn state ->
      %{state | transactions: %{}, live: nil, divergence: nil, faults: %{}, notify: nil}
    end)

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
      :sys.replace_state(DeploymentNode, fn _state -> previous_node_state end)
      restore_persistent(previous_persisted)
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
        "manifest" => built.manifest,
        "manifest_digest" =>
          built.manifest
          |> OpenAgents.Forge.BuildProtocol.canonical_json()
          |> OpenAgents.Forge.BuildArtifact.digest(),
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
    assert %{"state" => "image", "reason" => "no_live_target", "ready" => true} =
             BootConverge.converge(@repo)

    # A target that is not live.
    insert_target!("failed", %{})

    assert %{"state" => "image", "reason" => "no_live_target", "ready" => true} =
             BootConverge.converge(@repo)

    # A live target whose artifact this node does not have (replaced node).
    {missing_module, missing_binary} = scratch_beam(OpenAgents.Scratch.BootConvergeMissing)
    missing = artifact(missing_module, missing_binary)
    insert_target!("live", missing.details)
    assert %{"state" => "degraded", "ready" => false} = BootConverge.converge(@repo)

    # A live target with an off-allowlist module in the tar.
    {module, binary} = scratch_beam(OpenAgents.NotAllowed.BootConvergeOffLimits)
    off_limit = artifact(module, binary)
    artifact_abs = Path.join(Repos.data_dir(), off_limit.details["artifact"])
    File.write!(artifact_abs, off_limit.built.bytes)
    insert_target!("live", off_limit.details)

    assert %{"state" => "degraded", "ready" => false} =
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

  test "convergence retains current and predecessor artifacts and prunes older cache entries" do
    {predecessor_module, predecessor_binary} =
      scratch_beam(OpenAgents.Scratch.BootConvergePredecessor)

    predecessor = artifact(predecessor_module, predecessor_binary)

    File.write!(
      Path.join(Repos.data_dir(), predecessor.details["artifact"]),
      predecessor.built.bytes
    )

    insert_target!("live", predecessor.details)

    {current_module, current_binary} = scratch_beam(OpenAgents.Scratch.BootConvergeCurrent)
    current = artifact(current_module, current_binary)
    File.write!(Path.join(Repos.data_dir(), current.details["artifact"]), current.built.bytes)
    insert_target!("live", current.details)

    orphan_digest = String.duplicate("a", 64)
    orphan_path = Path.join([Repos.data_dir(), "beams", orphan_digest <> ".tar"])
    File.write!(orphan_path, "obsolete-cache-entry")
    unrelated_path = Path.join([Repos.data_dir(), "beams", "README"])
    File.write!(unrelated_path, "operator note")

    assert %{"state" => "converged"} = BootConverge.converge(@repo)
    assert File.exists?(Path.join(Repos.data_dir(), current.details["artifact"]))
    assert File.exists?(Path.join(Repos.data_dir(), predecessor.details["artifact"]))
    refute File.exists?(orphan_path)
    assert File.exists?(unrelated_path)

    :code.purge(current_module)
    :code.delete(current_module)
  end

  test "a live target without artifact identity stays out of readiness" do
    insert_target!("live", %{})

    assert %{
             "state" => "degraded",
             "ready" => false,
             "reason" => "live_artifact_identity_missing"
           } = BootConverge.converge(@repo)
  end

  test "readiness fails closed when a newer live target appears" do
    {module, binary} = scratch_beam(OpenAgents.Scratch.BootConvergeFreshness)
    artifact = artifact(module, binary)
    File.write!(Path.join(Repos.data_dir(), artifact.details["artifact"]), artifact.built.bytes)
    insert_target!("live", artifact.details)

    assert %{"state" => "converged", "ready" => true} = BootConverge.converge(@repo)

    previous_enabled = Application.get_env(:openagents, :forge_boot_converge_enabled)
    Application.put_env(:openagents, :forge_boot_converge_enabled, true)

    on_exit(fn -> restore_env(:forge_boot_converge_enabled, previous_enabled) end)

    assert BootConverge.ready?(@repo)

    newer =
      %Target{}
      |> Target.changeset(%{
        repo: @repo,
        sha: String.duplicate("e", 40),
        promoted_by: "operator:t",
        status: "promoted"
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(%{status: "deploying", details: %{}})
      |> Repo.update!()

    refute BootConverge.ready?(@repo)
    assert BootConverge.ready_for_deployment?(@repo, newer.id)

    newer
    |> Ecto.Changeset.change(%{status: "live"})
    |> Repo.update!()

    refute BootConverge.ready?(@repo)

    :code.purge(module)
    :code.delete(module)
  end

  test "the supervised worker retains degraded readiness and caps retry backoff" do
    insert_target!("live", %{})
    previous_enabled = Application.get_env(:openagents, :forge_boot_converge_enabled)
    previous_min = Application.get_env(:openagents, :forge_boot_retry_min_ms)
    previous_max = Application.get_env(:openagents, :forge_boot_retry_max_ms)

    Application.put_env(:openagents, :forge_boot_converge_enabled, true)
    Application.put_env(:openagents, :forge_boot_retry_min_ms, 10_000)
    Application.put_env(:openagents, :forge_boot_retry_max_ms, 20_000)

    name = Module.concat(__MODULE__, "Retry#{System.unique_integer([:positive])}")

    start_supervised!(
      Supervisor.child_spec(
        {BootConverge, name: name, repo: @repo},
        id: name
      )
    )

    server_state = :sys.get_state(name)
    convergence = BootConverge.state()

    refute convergence["ready"]
    assert convergence["state"] == "degraded"
    assert convergence["retry_in_ms"] == 10_000
    assert server_state.retry_ms == 20_000

    send(name, :retry_convergence)
    server_state = :sys.get_state(name)
    convergence = BootConverge.state()

    assert convergence["attempts"] == 2
    assert convergence["retry_in_ms"] == 20_000
    assert server_state.retry_ms == 20_000

    on_exit(fn ->
      restore_env(:forge_boot_converge_enabled, previous_enabled)
      restore_env(:forge_boot_retry_min_ms, previous_min)
      restore_env(:forge_boot_retry_max_ms, previous_max)
    end)
  end

  test "the supervised worker refreshes a ready image state" do
    previous_enabled = Application.get_env(:openagents, :forge_boot_converge_enabled)
    previous_min = Application.get_env(:openagents, :forge_boot_retry_min_ms)
    previous_max = Application.get_env(:openagents, :forge_boot_retry_max_ms)

    Application.put_env(:openagents, :forge_boot_converge_enabled, true)
    Application.put_env(:openagents, :forge_boot_retry_min_ms, 10_000)
    Application.put_env(:openagents, :forge_boot_retry_max_ms, 20_000)

    name = Module.concat(__MODULE__, "Ready#{System.unique_integer([:positive])}")

    start_supervised!(
      Supervisor.child_spec(
        {BootConverge, name: name, repo: @repo},
        id: name
      )
    )

    assert %{"state" => "image", "ready" => true} = BootConverge.state()
    assert :sys.get_state(name).retry_ms == 10_000

    send(name, :retry_convergence)
    assert :sys.get_state(name).retry_ms == 10_000

    send(name, :irrelevant_message)
    assert :sys.get_state(name).retry_ms == 10_000

    on_exit(fn ->
      restore_env(:forge_boot_converge_enabled, previous_enabled)
      restore_env(:forge_boot_retry_min_ms, previous_min)
      restore_env(:forge_boot_retry_max_ms, previous_max)
    end)
  end

  test "image-matching legacy target remains ready without artifact metadata" do
    target = insert_target!("live", %{})
    previous_enabled = Application.get_env(:openagents, :forge_boot_converge_enabled)
    Application.put_env(:openagents, :forge_boot_converge_enabled, true)

    on_exit(fn -> restore_env(:forge_boot_converge_enabled, previous_enabled) end)

    target
    |> Ecto.Changeset.change(%{sha: OpenAgents.BuildInfo.revision()})
    |> Repo.update!()

    assert %{
             "state" => "image",
             "ready" => true,
             "reason" => "image_matches_live",
             "sha" => "image"
           } = BootConverge.converge(@repo)

    assert BootConverge.ready?(@repo)
  end

  test "image-matching rolling target remains ready despite a non-direct artifact" do
    runtime_sha = OpenAgents.BuildInfo.revision()
    runtime_digest = "sha256:" <> String.duplicate("f", 64)
    previous_digest = Application.get_env(:openagents, :image_digest)
    Application.put_env(:openagents, :image_digest, runtime_digest)

    on_exit(fn -> restore_env(:image_digest, previous_digest) end)

    {module, binary} = scratch_beam(OpenAgents.NotAllowed.BootConvergeRollingImage)
    artifact = artifact(module, binary)

    target =
      insert_target!(
        "live",
        Map.put(artifact.details, "image_digest", runtime_digest)
      )

    target
    |> Ecto.Changeset.change(%{sha: runtime_sha})
    |> Repo.update!()

    previous_enabled = Application.get_env(:openagents, :forge_boot_converge_enabled)
    Application.put_env(:openagents, :forge_boot_converge_enabled, true)

    on_exit(fn -> restore_env(:forge_boot_converge_enabled, previous_enabled) end)

    assert %{
             "state" => "image",
             "ready" => true,
             "reason" => "image_matches_live",
             "sha" => ^runtime_sha
           } = BootConverge.converge(@repo)

    assert BootConverge.ready?(@repo)
    refute Code.ensure_loaded?(module)
  end

  test "a node running the authorized rolling image stays in readiness" do
    # An older live target whose artifact this node cannot install: without
    # the rolling-authority branch this node would degrade and leave rotation.
    insert_target!("live", %{})

    digest = enable_convergence_with_image!("sha256:" <> String.duplicate("1", 64))
    rolling = rolling_target!()
    authorize_rolling!(rolling, digest)

    assert %{
             "state" => "image",
             "ready" => true,
             "reason" => "image_matches_rolling_target"
           } = BootConverge.converge(@repo)

    assert BootConverge.ready?(@repo)
    assert BootConverge.classify(@repo) == :rolling

    # Once the rolling target settles, readiness follows the live-target path
    # with no flag change and no restart of the convergence worker.
    rolling
    |> Ecto.Changeset.change(%{
      status: "live",
      details: Map.put(rolling.details, "image_digest", digest)
    })
    |> Repo.update!()

    assert %{"state" => "image", "reason" => "image_matches_live", "ready" => true} =
             BootConverge.converge(@repo)

    assert BootConverge.ready?(@repo)
    assert BootConverge.classify(@repo) == :live
  end

  test "an image that is not the authorized rolling identity stays out of service" do
    insert_target!("live", %{})

    authorized = "sha256:" <> String.duplicate("1", 64)
    enable_convergence_with_image!("sha256:" <> String.duplicate("2", 64))
    authorize_rolling!(rolling_target!(), authorized)

    assert BootConverge.classify(@repo) == :divergent
    assert %{"state" => "degraded", "ready" => false} = BootConverge.converge(@repo)
    refute BootConverge.ready?(@repo)
  end

  test "a rolling target that published no authority admits no image" do
    insert_target!("live", %{})
    enable_convergence_with_image!("sha256:" <> String.duplicate("1", 64))
    rolling_target!()

    assert BootConverge.classify(@repo) == :divergent
    assert %{"state" => "degraded", "ready" => false} = BootConverge.converge(@repo)
    refute BootConverge.ready?(@repo)
  end

  test "classify answers for any node identity in the fleet" do
    digest = "sha256:" <> String.duplicate("1", 64)
    previous_digest = "sha256:" <> String.duplicate("2", 64)

    insert_target!("live", %{"image_digest" => previous_digest})
    enable_convergence_with_image!(digest)
    authorize_rolling!(rolling_target!(), digest)

    live_sha = String.duplicate("d", 40)
    rolling_sha = OpenAgents.BuildInfo.revision()

    assert BootConverge.classify(@repo, %{sha: live_sha, image_digest: previous_digest}) == :live

    assert BootConverge.classify(@repo, %{sha: rolling_sha, image_digest: digest}) == :rolling

    assert BootConverge.classify(@repo, %{sha: rolling_sha, image_digest: previous_digest}) ==
             :divergent

    assert BootConverge.classify(@repo, %{sha: live_sha, image_digest: digest}) == :divergent
    assert BootConverge.classify(@repo, %{sha: rolling_sha, image_digest: nil}) == :divergent
  end

  # A `needs_rolling_replace` target for this repo, carrying this image's exact
  # revision the way a replacement node's image does.
  defp rolling_target! do
    %Target{}
    |> Target.changeset(%{
      repo: @repo,
      sha: String.duplicate("e", 40),
      promoted_by: "operator:t",
      status: "promoted"
    })
    |> Repo.insert!()
    |> Ecto.Changeset.change(%{
      status: "needs_rolling_replace",
      sha: OpenAgents.BuildInfo.revision()
    })
    |> Repo.update!()
  end

  defp authorize_rolling!(target, image_digest) do
    {:ok, authorized} =
      OpenAgents.Forge.Targets.authorize_rolling_replacement(target.id, %{
        sha: target.sha,
        image_digest: image_digest,
        previous_sha: String.duplicate("d", 40),
        previous_image_digest: "sha256:" <> String.duplicate("9", 64),
        expected_nodes: [to_string(Node.self())],
        authorized_by: "operator:t"
      })

    authorized
  end

  defp enable_convergence_with_image!(digest) do
    previous_enabled = Application.get_env(:openagents, :forge_boot_converge_enabled)
    previous_digest = Application.get_env(:openagents, :image_digest)
    Application.put_env(:openagents, :forge_boot_converge_enabled, true)
    Application.put_env(:openagents, :image_digest, digest)

    on_exit(fn ->
      restore_env(:forge_boot_converge_enabled, previous_enabled)
      restore_env(:image_digest, previous_digest)
    end)

    digest
  end

  test "rolling target stays degraded when its image digest does not match the runtime" do
    runtime_sha = OpenAgents.BuildInfo.revision()
    previous_digest = Application.get_env(:openagents, :image_digest)
    Application.put_env(:openagents, :image_digest, "sha256:" <> String.duplicate("f", 64))

    on_exit(fn -> restore_env(:image_digest, previous_digest) end)

    {module, binary} = scratch_beam(OpenAgents.NotAllowed.BootConvergeWrongImage)
    artifact = artifact(module, binary)
    File.write!(Path.join(Repos.data_dir(), artifact.details["artifact"]), artifact.built.bytes)

    target =
      insert_target!(
        "live",
        Map.put(artifact.details, "image_digest", "sha256:" <> String.duplicate("e", 64))
      )

    target
    |> Ecto.Changeset.change(%{sha: runtime_sha})
    |> Repo.update!()

    assert %{"state" => "degraded", "ready" => false} = BootConverge.converge(@repo)
  end

  test "an unreadable cache entry degrades with a bounded reason" do
    {module, binary} = scratch_beam(OpenAgents.Scratch.BootConvergeUnreadable)
    artifact = artifact(module, binary)
    artifact_abs = Path.join(Repos.data_dir(), artifact.details["artifact"])
    File.mkdir_p!(artifact_abs)
    insert_target!("live", artifact.details)

    assert %{
             "state" => "degraded",
             "ready" => false,
             "reason" => "artifact_cache_read_failed"
           } = BootConverge.converge(@repo)
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)

  defp restore_persistent(:missing), do: :persistent_term.erase({DeploymentNode, :state})

  defp restore_persistent(state),
    do: :persistent_term.put({DeploymentNode, :state}, state)
end
