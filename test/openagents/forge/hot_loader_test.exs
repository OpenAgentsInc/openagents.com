defmodule OpenAgents.Forge.HotLoaderTest do
  use OpenAgents.DataCase, async: false
  @moduletag :capture_log

  alias OpenAgents.Forge.ArtifactFixtures
  alias OpenAgents.Forge.DeployReceipt
  alias OpenAgents.Forge.DeploymentNode
  alias OpenAgents.Forge.HotLoader
  alias OpenAgents.Forge.PushReceipt
  alias OpenAgents.Forge.Target

  @builds_topic "forge:builds"
  @deploys_topic "forge:deploys"

  # NOTE: OpenAgents.DataCase already runs the sandbox in shared mode for
  # async: false tests (start_owner!(shared: true)), so the HotLoader
  # GenServer shares the test connection without an explicit mode call.
  setup do
    base = Path.join(System.tmp_dir!(), "hot-loader-#{System.unique_integer([:positive])}")
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_node_state = :sys.get_state(DeploymentNode)
    previous_persisted = :persistent_term.get({DeploymentNode, :state}, :missing)
    Application.put_env(:openagents, :forge_data_dir, base)
    :persistent_term.erase({DeploymentNode, :state})

    :sys.replace_state(DeploymentNode, fn state ->
      %{state | transactions: %{}, live: nil, divergence: nil, faults: %{}, notify: nil}
    end)

    pid =
      case Process.whereis(HotLoader) do
        nil -> start_supervised!(HotLoader)
        pid -> pid
      end

    on_exit(fn ->
      if previous_data,
        do: Application.put_env(:openagents, :forge_data_dir, previous_data),
        else: Application.delete_env(:openagents, :forge_data_dir)

      File.rm_rf(base)
      :sys.replace_state(DeploymentNode, fn _state -> previous_node_state end)
      restore_persistent(previous_persisted)
    end)

    %{loader: pid}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp unique_sha, do: 20 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # Compiles a fresh OpenAgents.Scratch module, then unloads it so the hot-load
  # itself is what brings it into the running system.
  defp compiled_scratch_module do
    n = System.unique_integer([:positive])
    name = "Elixir.OpenAgents.Scratch.HotDemo#{n}"
    revision = "v#{n}"

    [{mod, binary}] =
      Code.compile_string("defmodule #{name} do\n  def revision, do: \"#{revision}\"\nend\n")

    unload(mod)
    on_exit(fn -> unload(mod) end)
    %{mod: mod, name: name, revision: revision, binary: binary}
  end

  defp unload(mod) do
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)
  end

  defp restore_persistent(:missing), do: :persistent_term.erase({DeploymentNode, :state})

  defp restore_persistent(state),
    do: :persistent_term.put({DeploymentNode, :state}, state)

  defp artifact(entries, sha) do
    built = ArtifactFixtures.create!("openagents.com", sha, entries)
    path = ArtifactFixtures.write!(built)
    on_exit(fn -> File.rm(path) end)

    %{
      artifact: path,
      artifact_digest: built.digest,
      build_id: built.build_id,
      manifest: built.manifest,
      modules: Enum.map(built.beams, & &1.module)
    }
  end

  defp malformed_artifact(entries) do
    path =
      Path.join(System.tmp_dir!(), "forge-malformed-#{System.unique_integer([:positive])}.tar")

    tar_entries =
      Enum.map(entries, fn {module_name, binary} ->
        {String.to_charlist("beams/#{module_name}.beam"), binary}
      end)

    :ok = :erl_tar.create(String.to_charlist(path), tar_entries)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp build_payload(target, sha, artifact) do
    Map.merge(artifact, %{repo: "openagents.com", sha: sha, target_id: target.id})
  end

  defp insert_target(sha, status) do
    {:ok, target} =
      %Target{}
      |> Target.changeset(%{
        repo: "openagents.com",
        sha: sha,
        promoted_by: "test-op",
        status: status
      })
      |> Repo.insert()

    target
  end

  defp broadcast_build_ready(loader, build) do
    Phoenix.PubSub.broadcast(OpenAgents.PubSub, @builds_topic, {:forge_build_ready, build})
    # The GenServer handles builds serially; a state probe returns only
    # after the broadcast above has been fully processed.
    :sys.get_state(loader)
  end

  defp deploy_receipt(sha) do
    Repo.one(from r in DeployReceipt, where: r.sha == ^sha)
  end

  # ── cases ────────────────────────────────────────────────────────────────

  test "happy path: build_ready hot-loads the module fleet-wide and receipts it", %{
    loader: loader
  } do
    %{mod: mod, name: name, revision: revision, binary: binary} = compiled_scratch_module()
    refute Code.ensure_loaded?(mod)

    sha = unique_sha()
    target = insert_target(sha, "built")
    artifact = artifact([{name, binary}], sha)

    Phoenix.PubSub.subscribe(OpenAgents.PubSub, @deploys_topic)

    broadcast_build_ready(loader, build_payload(target, sha, artifact))

    receipt = deploy_receipt(sha)
    assert Code.ensure_loaded?(mod)
    assert mod.revision() == revision

    assert Repo.get!(Target, target.id).status == "live"

    assert receipt.result == "live"
    assert receipt.repo == "openagents.com"

    # #181: a deploy receipt written after the key exists names its repository,
    # so `Changelog` and `Evidence` read a key rather than resolve a name.
    assert receipt.repository_id == "00000000-0000-4000-8000-000000000001"

    assert receipt.target_id == target.id
    assert receipt.modules == [name]
    assert receipt.canary == "ok"
    assert receipt.nodes == ["#{Node.self()}=committed"]
    assert receipt.expected_nodes == [to_string(Node.self())]
    assert receipt.rollback_verified == nil
    assert is_binary(receipt.artifact_digest)
    assert is_binary(receipt.manifest_digest)

    assert_receive {:forge_deploy, %{repo: "openagents.com", sha: ^sha, result: "live"}}
  end

  test "a participant prepare refusal becomes a durable failed deployment", %{loader: loader} do
    %{mod: mod, name: name, binary: binary} = compiled_scratch_module()
    sha = unique_sha()
    target = insert_target(sha, "built")
    artifact = artifact([{name, binary}], sha)

    :sys.replace_state(DeploymentNode, fn state ->
      %{state | faults: %{prepare: :error}}
    end)

    Phoenix.PubSub.subscribe(OpenAgents.PubSub, @deploys_topic)
    broadcast_build_ready(loader, build_payload(target, sha, artifact))

    refute Code.ensure_loaded?(mod)
    assert Repo.get!(Target, target.id).status == "failed"

    receipt = deploy_receipt(sha)
    assert receipt.result == "failed"
    assert receipt.error_code == "prepare_failed"
    assert receipt.rollback_verified == false

    assert_receive {:forge_deploy, %{repo: "openagents.com", sha: ^sha, result: "failed"}}
  end

  test "a finalize refusal keeps durable live authority while fencing readiness", %{
    loader: loader
  } do
    %{mod: mod, name: name, revision: revision, binary: binary} = compiled_scratch_module()
    sha = unique_sha()
    target = insert_target(sha, "built")
    artifact = artifact([{name, binary}], sha)

    :sys.replace_state(DeploymentNode, fn state ->
      %{state | faults: %{finalize: :error}}
    end)

    Phoenix.PubSub.subscribe(OpenAgents.PubSub, @deploys_topic)
    broadcast_build_ready(loader, build_payload(target, sha, artifact))

    assert Code.ensure_loaded?(mod)
    assert mod.revision() == revision
    assert Repo.get!(Target, target.id).status == "live"
    assert deploy_receipt(sha).result == "live"
    refute DeploymentNode.health()["ready"]

    assert_receive {:forge_deploy, %{repo: "openagents.com", sha: ^sha, result: "live"}}
  end

  test "allowlist refusal: off-allowlist module means needs_rolling_replace and no load", %{
    loader: loader
  } do
    %{mod: mod, name: name, binary: binary} = compiled_scratch_module()

    sha = unique_sha()
    target = insert_target(sha, "built")
    off_name = "Elixir.OpenAgents.Turns.Whatever#{System.unique_integer([:positive])}"
    [{off_mod, off_binary}] = Code.compile_string("defmodule #{off_name} do\nend")
    unload(off_mod)
    artifact = artifact([{name, binary}, {off_name, off_binary}], sha)

    Phoenix.PubSub.subscribe(OpenAgents.PubSub, @deploys_topic)

    broadcast_build_ready(loader, build_payload(target, sha, artifact))

    # Never a partial load: even the allowlisted module stays unloaded.
    refute Code.ensure_loaded?(mod)

    assert Repo.get!(Target, target.id).status == "needs_rolling_replace"

    receipt = deploy_receipt(sha)
    assert receipt.result == "needs_rolling_replace"

    details = Repo.get!(Target, target.id).details
    assert details["reasons"] == ["off_allowlist:#{off_name}"]

    # RELEASE-009: the lane was chosen in front, and the target carries the
    # fleet topology verdict it was chosen against.
    assert details["topology"]["schema"] == "openagents.deployment-lane.topology.v1"
    assert details["topology"]["nodes"] >= 1
    assert details["topology"]["unreadable"] == 0

    assert_receive {:forge_deploy,
                    %{repo: "openagents.com", sha: ^sha, result: "needs_rolling_replace"}}
  end

  test "a corrupt artifact fails verification before creating module atoms", %{loader: loader} do
    %{mod: mod, name: name, binary: binary} = compiled_scratch_module()
    corrupt_name = "Elixir.OpenAgents.Scratch.Corrupt#{System.unique_integer([:positive])}"

    sha = unique_sha()
    target = insert_target(sha, "built")
    artifact = malformed_artifact([{name, binary}, {corrupt_name, <<1, 2, 3>>}])

    Phoenix.PubSub.subscribe(OpenAgents.PubSub, @deploys_topic)

    broadcast_build_ready(loader, %{
      repo: "openagents.com",
      sha: sha,
      target_id: target.id,
      artifact: artifact,
      modules: [name, corrupt_name]
    })

    # The good module loaded first must have been reverted (purged) too.
    refute Code.ensure_loaded?(mod)
    assert Repo.get!(Target, target.id).status == "failed"
    assert deploy_receipt(sha).result == "failed"

    # #181: the failed-load path writes its own receipt, and it names the
    # repository too. Dropping the key from `HotLoader.insert_receipt/9` turns
    # this red.
    assert deploy_receipt(sha).repository_id == "00000000-0000-4000-8000-000000000001"

    assert_receive {:forge_deploy, %{repo: "openagents.com", sha: ^sha, result: "failed"}}
  end

  test "push_to_live_ms is measured from the matching push receipt", %{loader: loader} do
    %{name: name, binary: binary} = compiled_scratch_module()

    sha = unique_sha()
    target = insert_target(sha, "built")
    artifact = artifact([{name, binary}], sha)

    {:ok, _push} =
      %PushReceipt{}
      |> PushReceipt.changeset(%{
        repo: "openagents.com",
        wal_seq: System.unique_integer([:positive]),
        principal: "test-op",
        refs: %{"refs/heads/main" => %{"old" => String.duplicate("0", 40), "new" => sha}}
      })
      |> Repo.insert()

    broadcast_build_ready(loader, build_payload(target, sha, artifact))

    receipt = deploy_receipt(sha)
    assert receipt.result == "live"
    assert is_integer(receipt.push_to_live_ms)
    assert receipt.push_to_live_ms >= 0
  end

  test "push_to_live_ms resolves a logical repository to its receipt storage key", %{
    loader: loader
  } do
    storage_key = Ecto.UUID.generate()

    OpenAgents.Repositories.Repository
    |> where([repository], repository.name == "openagents.com")
    |> Repo.update_all(set: [storage_key: storage_key])

    %{name: name, binary: binary} = compiled_scratch_module()
    sha = unique_sha()
    target = insert_target(sha, "built")
    artifact = artifact([{name, binary}], sha)

    {:ok, _push} =
      %PushReceipt{}
      |> PushReceipt.changeset(%{
        repo: storage_key,
        wal_seq: System.unique_integer([:positive]),
        principal: "test-op",
        refs: %{
          "refs/heads/main" => %{"old" => String.duplicate("0", 40), "new" => sha}
        }
      })
      |> Repo.insert()

    broadcast_build_ready(loader, build_payload(target, sha, artifact))

    receipt = deploy_receipt(sha)
    assert receipt.result == "live"
    assert is_integer(receipt.push_to_live_ms)
  end

  test "push_to_live_ms is nil when no push receipt matches", %{loader: loader} do
    %{name: name, binary: binary} = compiled_scratch_module()

    sha = unique_sha()
    target = insert_target(sha, "built")
    artifact = artifact([{name, binary}], sha)

    broadcast_build_ready(loader, build_payload(target, sha, artifact))

    receipt = deploy_receipt(sha)
    assert receipt.result == "live"
    assert receipt.push_to_live_ms == nil
  end

  test "allowlisted?/2: exact entries, prefix entries, Elixir. prefix stripping" do
    allowlist = ["OpenAgents.Scratch.", "OpenAgents.BuildInfo"]

    assert HotLoader.allowlisted?("OpenAgents.BuildInfo", allowlist)
    assert HotLoader.allowlisted?("Elixir.OpenAgents.BuildInfo", allowlist)
    assert HotLoader.allowlisted?("OpenAgents.Scratch.Anything", allowlist)
    assert HotLoader.allowlisted?("Elixir.OpenAgents.Scratch.Deep.Nested", allowlist)

    # Exact entries are not prefixes.
    refute HotLoader.allowlisted?("OpenAgents.BuildInfoExtra", allowlist)
    refute HotLoader.allowlisted?("OpenAgents.BuildInfo.Sub", allowlist)
    # Prefix entries are not exact-matched without the trailing segment.
    refute HotLoader.allowlisted?("OpenAgents.Scratch", allowlist)
    refute HotLoader.allowlisted?("OpenAgents.Turns.Whatever", allowlist)
    refute HotLoader.allowlisted?("Anything", [])
  end

  test "extract!/1 verifies both successful and malformed artifacts" do
    %{mod: mod, name: name, binary: binary} = compiled_scratch_module()
    built = artifact([{name, binary}], unique_sha())

    assert [{^mod, extracted_binary}] = HotLoader.extract!(built.artifact)
    assert is_binary(extracted_binary)
    assert {:ok, {^mod, _md5}} = :beam_lib.md5(extracted_binary)

    malformed = malformed_artifact([{name, binary}])

    assert_raise RuntimeError, ~r/artifact verification failed/, fn ->
      HotLoader.extract!(malformed)
    end
  end

  test "duplicate startup and unrelated messages leave the loader intact", %{loader: loader} do
    assert {:error, {:already_started, ^loader}} = HotLoader.start_link()
    send(loader, :unrelated_message)
    assert :sys.get_state(loader) == %{}
  end

  test "OpenAgents.BuildInfo compiled-in revision is the boot image" do
    assert OpenAgents.BuildInfo.revision() == "image"
    assert OpenAgents.BuildInfo.loaded_at() == nil
  end
end
