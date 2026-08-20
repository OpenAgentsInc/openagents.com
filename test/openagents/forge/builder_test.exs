defmodule OpenAgents.Forge.BuilderTest do
  use OpenAgents.DataCase, async: false
  import Ecto.Query
  alias OpenAgents.Forge.BuildExecutor
  alias OpenAgents.Forge.BuildExecutor.Sidecar
  alias OpenAgents.Forge.BuildReceipt
  alias OpenAgents.Forge.Builder
  alias OpenAgents.Forge.FakeBuildExecutor
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.Target
  alias OpenAgents.Forge.Targets

  describe "Sidecar adapter boundaries" do
    test "sidecar repository URLs never contain the operator credential" do
      previous_url = Application.get_env(:openagents, :forge_internal_git_url)
      previous_token = Application.get_env(:openagents, :forge_operator_token)

      on_exit(fn ->
        Application.put_env(:openagents, :forge_internal_git_url, previous_url)
        Application.put_env(:openagents, :forge_operator_token, previous_token)
      end)

      Application.put_env(:openagents, :forge_internal_git_url, "http://forge.internal/git")
      Application.put_env(:openagents, :forge_operator_token, "forge-secret-sentinel")

      assert Sidecar.repo_url("openagents.com") ==
               "http://forge.internal/git/openagents.com.git"

      refute Sidecar.repo_url("openagents.com") =~ "forge-secret-sentinel"
    end

    test "bound_output truncates past the bound" do
      assert BuildExecutor.bound_output("short") == "short"

      long = String.duplicate("x", 10_000)
      bounded = BuildExecutor.bound_output(long)
      assert byte_size(bounded) <= 8_192 + byte_size("\n[truncated]")
      assert String.ends_with?(bounded, "[truncated]")
    end
  end

  describe "Builder" do
    setup do
      base = Path.join(System.tmp_dir!(), "forge-builder-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      previous_data = Application.get_env(:openagents, :forge_data_dir)
      previous_wal = Application.get_env(:openagents, :forge_wal_dir)
      Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
      Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))
      Application.put_env(:openagents, :forge_build_executor, FakeBuildExecutor)

      on_exit(fn ->
        Application.put_env(:openagents, :forge_data_dir, previous_data)
        Application.put_env(:openagents, :forge_wal_dir, previous_wal)
        Application.delete_env(:openagents, :forge_build_executor)
        Application.delete_env(:openagents, :fake_build_result)
        File.rm_rf(base)
      end)

      # The forge supervisor may start the Builder itself once P3 is wired
      # in; only start one here when it is not already running.
      unless Process.whereis(Builder), do: start_supervised!({Builder, []})

      Phoenix.PubSub.subscribe(OpenAgents.PubSub, "forge:builds")
      %{sha: seeded_commit("openagents.com"), data_dir: Path.join(base, "data")}
    end

    test "promotion builds, writes artifact tar + receipt, advances to built",
         %{sha: sha, data_dir: data_dir} do
      suffix = System.unique_integer([:positive])
      module = "Elixir.OpenAgents.Scratch.BuilderTest#{suffix}"

      [beam] =
        beams =
        FakeBuildExecutor.beams_for("""
        defmodule OpenAgents.Scratch.BuilderTest#{suffix} do
          def answer, do: 42
        end
        """)

      assert beam.module == module
      assert is_binary(beam.binary)

      Application.put_env(
        :openagents,
        :fake_build_result,
        {:ok, %{beams: beams, warnings: "warn: something minor", tests: nil, duration_ms: 123}}
      )

      {:ok, target} = Targets.promote("openagents.com", sha, "test-operator")

      assert_receive {:forge_build_ready,
                      %{
                        repo: "openagents.com",
                        sha: ^sha,
                        target_id: target_id,
                        artifact: artifact,
                        modules: [^module]
                      }},
                     5_000

      assert target_id == target.id

      # Artifact cache is addressed by the full tar digest, never by source SHA.
      assert Path.dirname(artifact) == Path.join(data_dir, "beams")
      assert Path.basename(artifact) =~ ~r/^[0-9a-f]{64}\.tar$/
      assert File.exists?(artifact)

      {:ok, entries} = :erl_tar.extract(String.to_charlist(artifact), [:memory])
      assert Enum.any?(entries, fn {name, _binary} -> to_string(name) == "manifest.json" end)

      assert Enum.any?(entries, fn {name, _binary} ->
               to_string(name) == "beams/#{module}.beam"
             end)

      # Receipt row.
      receipt = Repo.get_by!(BuildReceipt, repo: "openagents.com", sha: sha)
      assert receipt.target_id == target.id
      assert receipt.modules == [module]
      assert receipt.warnings == "warn: something minor"
      assert receipt.tests == nil
      assert receipt.duration_ms == 123
      assert receipt.status == "complete"
      assert receipt.artifact_digest =~ ~r/^[0-9a-f]{64}$/
      assert receipt.artifact == Path.join("beams", receipt.artifact_digest <> ".tar")
      assert receipt.manifest["source_sha"] == sha

      # Target advanced to built with artifact + modules in details.
      built = await_status(target, "built")
      assert built.details["artifact"] == receipt.artifact
      assert built.details["artifact_digest"] == receipt.artifact_digest
      assert built.details["build_id"] == receipt.id
      assert built.details["modules"] == [module]
    end

    test "build failure advances the target to failed with bounded error", %{sha: sha} do
      Application.put_env(
        :openagents,
        :fake_build_result,
        {:error, "boom\n" <> String.duplicate("x", 20_000)}
      )

      {:ok, target} = Targets.promote("openagents.com", sha, "test-operator")

      failed = await_status(target, "failed")
      assert failed.status == "failed"
      assert String.starts_with?(failed.details["error"], "build_failed: boom")
      assert byte_size(failed.details["error"]) <= 8_192 + byte_size("\n[truncated]")

      receipt = Repo.get_by!(BuildReceipt, target_id: target.id)
      assert receipt.status == "failed"
      assert receipt.error_code == "build_failed"

      refute_receive {:forge_build_ready, _payload}, 200

      # The Builder survived the failed build and handles the next one.
      suffix = System.unique_integer([:positive])

      beams =
        FakeBuildExecutor.beams_for("""
        defmodule OpenAgents.Scratch.BuilderRecovery#{suffix} do
          def ok, do: :ok
        end
        """)

      Application.put_env(
        :openagents,
        :fake_build_result,
        {:ok, %{beams: beams, warnings: "", tests: nil, duration_ms: 1}}
      )

      {:ok, target2} = Targets.promote("openagents.com", sha, "test-operator")
      target2_id = target2.id
      assert_receive {:forge_build_ready, %{sha: ^sha, target_id: ^target2_id}}, 5_000
    end

    test "recovery expires an abandoned build ID before creating a new attempt", %{sha: sha} do
      previous_threshold =
        Application.get_env(:openagents, :forge_build_abandoned_after_ms)

      Application.put_env(:openagents, :forge_build_abandoned_after_ms, 0)

      on_exit(fn ->
        if previous_threshold,
          do:
            Application.put_env(
              :openagents,
              :forge_build_abandoned_after_ms,
              previous_threshold
            ),
          else: Application.delete_env(:openagents, :forge_build_abandoned_after_ms)
      end)

      suffix = System.unique_integer([:positive])

      beams =
        FakeBuildExecutor.beams_for("""
        defmodule OpenAgents.Scratch.RecoveredBuild#{suffix} do
          def ok, do: :ok
        end
        """)

      Application.put_env(
        :openagents,
        :fake_build_result,
        {:ok, %{beams: beams, warnings: "", tests: nil, duration_ms: 1}}
      )

      target =
        %Target{}
        |> Target.changeset(%{
          repo: "openagents.com",
          sha: sha,
          promoted_by: "test-operator",
          status: "promoted"
        })
        |> Repo.insert!()
        |> Ecto.Changeset.change(%{status: "building"})
        |> Repo.update!()

      abandoned_id = Ecto.UUID.generate()

      %BuildReceipt{id: abandoned_id}
      |> BuildReceipt.start_changeset(%{
        repo: target.repo,
        sha: target.sha,
        target_id: target.id,
        baseline_manifest: nil
      })
      |> Repo.insert!()

      builder = Process.whereis(Builder)
      send(builder, :recover_abandoned)
      _state = :sys.get_state(builder)

      assert_receive {:forge_build_ready, %{target_id: target_id, build_id: recovered_id}}, 5_000
      assert target_id == target.id
      refute recovered_id == abandoned_id

      receipts =
        BuildReceipt
        |> where([b], b.target_id == ^target.id)
        |> order_by([b], asc: b.inserted_at)
        |> Repo.all()

      assert Enum.map(receipts, & &1.status) == ["expired", "complete"]
      assert Enum.map(receipts, & &1.id) == [abandoned_id, recovered_id]
      assert Enum.at(receipts, 0).error_code == "builder_restart_expired"
    end
  end

  # The Builder does its DB work asynchronously; poll the target row until
  # it reaches the expected status.
  defp await_status(target, status, attempts \\ 50)

  defp await_status(target, status, 0) do
    flunk("target #{target.id} never reached status #{inspect(status)}")
  end

  defp await_status(target, status, attempts) do
    reloaded = Repo.reload!(target)

    if reloaded.status == status do
      reloaded
    else
      Process.sleep(100)
      await_status(target, status, attempts - 1)
    end
  end

  # A real commit in the bare repo via plumbing (no clone, no WAL needed:
  # promotability checks the WAL-backed local repo, and an absent WAL index
  # means nothing to replay).
  defp seeded_commit(repo) do
    path = Repos.ensure_repo!(repo)

    {blob, 0} = git_in(path, ["hash-object", "-w", "--stdin"], "hello builder\n")
    {tree, 0} = git_in(path, ["mktree"], "100644 blob #{String.trim(blob)}\tfile.txt\n")

    {commit, 0} =
      git_in(path, ["commit-tree", String.trim(tree), "-m", "seed"], "",
        env: [
          {"GIT_AUTHOR_NAME", "t"},
          {"GIT_AUTHOR_EMAIL", "t@t"},
          {"GIT_COMMITTER_NAME", "t"},
          {"GIT_COMMITTER_EMAIL", "t@t"}
        ]
      )

    sha = String.trim(commit)
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", sha])
    sha
  end

  defp git_in(path, args, stdin, opts \\ []) do
    input = Path.join(System.tmp_dir!(), "builder-stdin-#{System.unique_integer([:positive])}")
    File.write!(input, stdin)

    try do
      System.cmd(
        "sh",
        ["-c", ~s(exec git --git-dir "$GD" "$@" < "$IN"), "sh"] ++ args,
        env: [{"GD", path}, {"IN", input}] ++ Keyword.get(opts, :env, [])
      )
    after
      File.rm(input)
    end
  end
end
