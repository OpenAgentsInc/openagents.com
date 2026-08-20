defmodule OpenAgents.Forge.HotLoaderTest do
  use OpenAgents.DataCase, async: false
  @moduletag :capture_log

  alias OpenAgents.Forge.DeployReceipt
  alias OpenAgents.Forge.HotLoader
  alias OpenAgents.Forge.PushReceipt
  alias OpenAgents.Forge.Target

  @builds_topic "forge:builds"
  @deploys_topic "forge:deploys"

  # NOTE: OpenAgents.DataCase already runs the sandbox in shared mode for
  # async: false tests (start_owner!(shared: true)), so the HotLoader
  # GenServer shares the test connection without an explicit mode call.
  setup do
    pid =
      case Process.whereis(HotLoader) do
        nil -> start_supervised!(HotLoader)
        pid -> pid
      end

    %{loader: pid}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp unique_sha, do: 20 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # Compiles a fresh OpenAgents.Scratch module, then unloads it so the hot-load
  # itself is what brings it into the running system.
  defp compiled_scratch_module do
    n = System.unique_integer([:positive])
    name = "OpenAgents.Scratch.HotDemo#{n}"
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

  defp tar_artifact(entries) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "forge-hot-#{System.unique_integer([:positive])}.tar")

    tar_entries =
      Enum.map(entries, fn {module_name, binary} ->
        {String.to_charlist("Elixir.#{module_name}.beam"), binary}
      end)

    :ok = :erl_tar.create(String.to_charlist(path), tar_entries)
    on_exit(fn -> File.rm(path) end)
    path
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
    artifact = tar_artifact([{name, binary}])

    Phoenix.PubSub.subscribe(OpenAgents.PubSub, @deploys_topic)

    broadcast_build_ready(loader, %{
      repo: "openagents.com",
      sha: sha,
      target_id: target.id,
      artifact: artifact,
      modules: [name]
    })

    assert Code.ensure_loaded?(mod)
    assert mod.revision() == revision

    assert Repo.get!(Target, target.id).status == "live"

    receipt = deploy_receipt(sha)
    assert receipt.result == "live"
    assert receipt.repo == "openagents.com"
    assert receipt.target_id == target.id
    assert receipt.modules == [name]
    assert receipt.canary == "ok"
    assert receipt.nodes == ["#{Node.self()}=ok"]

    assert_receive {:forge_deploy, %{repo: "openagents.com", sha: ^sha, result: "live"}}
  end

  test "allowlist refusal: off-allowlist module means needs_rolling_replace and no load", %{
    loader: loader
  } do
    %{mod: mod, name: name, binary: binary} = compiled_scratch_module()

    sha = unique_sha()
    target = insert_target(sha, "built")
    artifact = tar_artifact([{name, binary}, {"OpenAgents.Turns.Whatever", <<0>>}])

    Phoenix.PubSub.subscribe(OpenAgents.PubSub, @deploys_topic)

    broadcast_build_ready(loader, %{
      repo: "openagents.com",
      sha: sha,
      target_id: target.id,
      artifact: artifact,
      modules: [name, "OpenAgents.Turns.Whatever"]
    })

    # Never a partial load: even the allowlisted module stays unloaded.
    refute Code.ensure_loaded?(mod)

    assert Repo.get!(Target, target.id).status == "needs_rolling_replace"

    receipt = deploy_receipt(sha)
    assert receipt.result == "needs_rolling_replace"

    offenders = Repo.get!(Target, target.id).details["modules"]
    assert offenders == ["OpenAgents.Turns.Whatever"]

    assert_receive {:forge_deploy,
                    %{repo: "openagents.com", sha: ^sha, result: "needs_rolling_replace"}}
  end

  test "canary revert: a corrupt beam reverts the whole artifact", %{loader: loader} do
    %{mod: mod, name: name, binary: binary} = compiled_scratch_module()
    corrupt_name = "OpenAgents.Scratch.Corrupt#{System.unique_integer([:positive])}"
    corrupt_mod = String.to_atom("Elixir.#{corrupt_name}")

    sha = unique_sha()
    target = insert_target(sha, "built")
    artifact = tar_artifact([{name, binary}, {corrupt_name, <<1, 2, 3>>}])

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
    refute Code.ensure_loaded?(corrupt_mod)

    assert Repo.get!(Target, target.id).status == "reverted"
    assert deploy_receipt(sha).result == "reverted"

    assert_receive {:forge_deploy, %{repo: "openagents.com", sha: ^sha, result: "reverted"}}
  end

  test "push_to_live_ms is measured from the matching push receipt", %{loader: loader} do
    %{name: name, binary: binary} = compiled_scratch_module()

    sha = unique_sha()
    target = insert_target(sha, "built")
    artifact = tar_artifact([{name, binary}])

    {:ok, _push} =
      %PushReceipt{}
      |> PushReceipt.changeset(%{
        repo: "openagents.com",
        wal_seq: System.unique_integer([:positive]),
        principal: "test-op",
        refs: %{"refs/heads/main" => %{"old" => String.duplicate("0", 40), "new" => sha}}
      })
      |> Repo.insert()

    broadcast_build_ready(loader, %{
      repo: "openagents.com",
      sha: sha,
      target_id: target.id,
      artifact: artifact,
      modules: [name]
    })

    receipt = deploy_receipt(sha)
    assert receipt.result == "live"
    assert is_integer(receipt.push_to_live_ms)
    assert receipt.push_to_live_ms >= 0
  end

  test "push_to_live_ms is nil when no push receipt matches", %{loader: loader} do
    %{name: name, binary: binary} = compiled_scratch_module()

    sha = unique_sha()
    target = insert_target(sha, "built")
    artifact = tar_artifact([{name, binary}])

    broadcast_build_ready(loader, %{
      repo: "openagents.com",
      sha: sha,
      target_id: target.id,
      artifact: artifact,
      modules: [name]
    })

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

  test "OpenAgents.BuildInfo compiled-in revision is the boot image" do
    assert OpenAgents.BuildInfo.revision() == "image"
    assert OpenAgents.BuildInfo.loaded_at() == nil
  end
end
