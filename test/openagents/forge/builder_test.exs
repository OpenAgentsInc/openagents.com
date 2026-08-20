defmodule OpenAgents.Forge.BuilderTest do
  use OpenAgents.DataCase, async: false
  alias OpenAgents.Forge.BuildExecutor
  alias OpenAgents.Forge.BuildExecutor.Sidecar
  alias OpenAgents.Forge.BuildReceipt
  alias OpenAgents.Forge.Builder
  alias OpenAgents.Forge.FakeBuildExecutor
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.Targets

  describe "pure Sidecar adapter pieces" do
    test "render_job serializes the two env-style lines the watcher sources" do
      assert Sidecar.render_job("abc123", "http://x:tok@127.0.0.1:8080/git/openagents.com.git") ==
               "SHA=abc123\nREPO_URL=http://x:tok@127.0.0.1:8080/git/openagents.com.git\n"
    end

    test "parse_result reads env-style lines, tolerating garbage" do
      contents = """
      STATUS=ok
      MODULES=Elixir.Foo,Elixir.Bar
      DURATION=7
      garbage-single-token
      """

      assert Sidecar.parse_result(contents) == %{
               "STATUS" => "ok",
               "MODULES" => "Elixir.Foo,Elixir.Bar",
               "DURATION" => "7"
             }

      assert Sidecar.parse_result("") == %{}
      assert Sidecar.parse_result("STATUS=error\n") == %{"STATUS" => "error"}
    end

    test "beams_from_tar reads entries back out of a beam tar, sorted" do
      tar = Path.join(System.tmp_dir!(), "beams-#{System.unique_integer([:positive])}.tar")

      :ok =
        :erl_tar.create(String.to_charlist(tar), [
          {~c"Elixir.Zeta.beam", "zeta-bytes"},
          {~c"Elixir.Alpha.beam", "alpha-bytes"}
        ])

      bytes = File.read!(tar)
      File.rm!(tar)

      assert {:ok,
              [
                %{module: "Elixir.Alpha", binary: "alpha-bytes"},
                %{module: "Elixir.Zeta", binary: "zeta-bytes"}
              ]} = Sidecar.beams_from_tar(bytes)

      assert {:error, _reason} = Sidecar.beams_from_tar("not a tar")
    end

    test "module_name strips path and extension" do
      assert Sidecar.module_name("ebin/Elixir.Foo.Bar.beam") == "Elixir.Foo.Bar"
      assert Sidecar.module_name("Elixir.Foo.beam") == "Elixir.Foo"
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

      # Artifact tar exists at <data_dir>/beams/<sha>.tar with beam entries.
      assert artifact == Path.join([data_dir, "beams", sha <> ".tar"])
      assert File.exists?(artifact)

      {:ok, entries} = :erl_tar.extract(String.to_charlist(artifact), [:memory])
      assert [{name, binary}] = entries
      assert to_string(name) == module <> ".beam"
      assert binary == beam.binary

      # Receipt row.
      receipt = Repo.get_by!(BuildReceipt, repo: "openagents.com", sha: sha)
      assert receipt.target_id == target.id
      assert receipt.modules == [module]
      assert receipt.warnings == "warn: something minor"
      assert receipt.tests == nil
      assert receipt.duration_ms == 123
      assert receipt.artifact == Path.join("beams", sha <> ".tar")

      # Target advanced to built with artifact + modules in details.
      built = await_status(target, "built")
      assert built.details["artifact"] == Path.join("beams", sha <> ".tar")
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
      assert String.starts_with?(failed.details["error"], "boom")
      assert byte_size(failed.details["error"]) <= 8_192 + byte_size("\n[truncated]")

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
