defmodule OpenAgents.Forge.BuildWorkerTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Forge.ArtifactFixtures
  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.BuildProtocol
  alias OpenAgents.Forge.BuildWorker

  @repo "openagents.com"
  @sha String.duplicate("c", 40)

  setup do
    root = Path.join(System.tmp_dir!(), "build-worker-#{System.unique_integer([:positive])}")
    queue = Path.join(root, "queue")
    artifacts = Path.join(root, "artifacts")
    builds = Path.join(root, "builds")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{queue: queue, artifacts: artifacts, builds: builds}
  end

  test "one JSON request produces an atomic verified artifact, bounded response, and retained log",
       %{queue: queue, artifacts: artifacts, builds: builds} do
    build_id = Ecto.UUID.generate()
    baseline = ArtifactFixtures.create!(@repo, String.duplicate("b", 40), []).manifest
    request = request(build_id, baseline)
    write_request!(queue, request)

    source = "defmodule OpenAgents.Scratch.WorkerProbe do\n def value, do: 42\nend"
    [{module, binary}] = Code.compile_string(source)
    :code.purge(module)
    :code.delete(module)
    retained = String.duplicate("compiler-output\n", 2_000)

    build_fun = fn claimed, workspace ->
      assert claimed["build_id"] == build_id
      assert claimed["source_sha"] == @sha

      assert Path.basename(workspace) ==
               "repo-" <> (:sha256 |> :crypto.hash(@repo) |> Base.encode16(case: :lower))

      {:ok, [%{module: Atom.to_string(module), binary: binary}],
       BuildArtifact.current_toolchain(), [], retained}
    end

    assert :processed =
             BuildWorker.run_once(queue, artifacts, builds, build_fun: build_fun)

    response_path = Path.join([queue, "responses", build_id <> ".json"])
    assert {:ok, response} = response_path |> File.read!() |> BuildProtocol.decode_response()
    assert response["status"] == "ok"
    assert response["build_id"] == build_id
    assert {:ok, response_stat} = File.stat(response_path)
    assert {:ok, response_dir_stat} = File.stat(Path.dirname(response_path))
    assert Bitwise.band(response_stat.mode, 0o777) == 0o640
    assert response_stat.uid == response_dir_stat.uid
    assert response_stat.gid == response_dir_stat.gid

    artifact_path = Path.join(artifacts, response["artifact_ref"])

    assert {:ok, verified} =
             artifact_path
             |> File.read!()
             |> BuildArtifact.verify(
               digest: response["artifact_digest"],
               repo: @repo,
               source_sha: @sha,
               build_id: build_id
             )

    assert verified.modules == ["Elixir.OpenAgents.Scratch.WorkerProbe"]
    assert verified.manifest["baseline"]["source_sha"] == String.duplicate("b", 40)

    output_path = Path.join(artifacts, response["output_ref"])
    assert File.read!(output_path) == retained
    assert response["output_digest"] == BuildArtifact.digest(retained)
    assert byte_size(response["output_excerpt"]) == 8_192
    assert {:ok, %{mode: mode}} = File.stat(output_path)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert {:ok, []} = File.ls(Path.join(queue, "requests"))
    assert {:ok, []} = File.ls(Path.join(queue, "running"))
    assert {:ok, []} = File.ls(Path.join(builds, "jobs"))
  end

  test "reuses one stable compiler workspace path across build attempts", context do
    baseline = ArtifactFixtures.create!(@repo, String.duplicate("b", 40), []).manifest
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()
    [{module, binary}] = Code.compile_string("defmodule OpenAgents.Scratch.StablePath do\nend")
    :code.purge(module)
    :code.delete(module)
    parent = self()

    build_fun = fn _request, workspace ->
      send(parent, {:workspace, workspace})

      {:ok, [%{module: Atom.to_string(module), binary: binary}],
       BuildArtifact.current_toolchain(), [], "ok"}
    end

    write_request!(context.queue, request(first_id, baseline))

    assert :processed =
             BuildWorker.run_once(context.queue, context.artifacts, context.builds,
               build_fun: build_fun
             )

    assert_receive {:workspace, first_workspace}

    write_request!(context.queue, request(second_id, baseline))

    assert :processed =
             BuildWorker.run_once(context.queue, context.artifacts, context.builds,
               build_fun: build_fun
             )

    assert_receive {:workspace, second_workspace}
    assert first_workspace == second_workspace
    refute String.contains?(first_workspace, first_id)
    refute String.contains?(second_workspace, second_id)
  end

  test "unknown request fields fail before the build callback runs", context do
    build_id = Ecto.UUID.generate()
    request = request(build_id, nil) |> Map.put("shell", "$(touch /tmp/owned)")
    encoded = Jason.encode!(request)
    path = Path.join([context.queue, "requests", build_id <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encoded)

    build_fun = fn _request, _workspace -> flunk("malformed request reached compiler") end

    assert :processed =
             BuildWorker.run_once(context.queue, context.artifacts, context.builds,
               build_fun: build_fun
             )

    response =
      context.queue
      |> Path.join("responses/#{build_id}.json")
      |> File.read!()
      |> then(fn bytes -> elem(BuildProtocol.decode_response(bytes), 1) end)

    assert response["status"] == "error"
    assert response["error_code"] == "unexpected_fields"
    assert Path.wildcard(Path.join(context.artifacts, "artifacts/*.tar")) == []
  end

  test "operator-only full output expires under the defined retention", context do
    output_dir = Path.join(context.artifacts, "output")
    File.mkdir_p!(output_dir)
    old_log = Path.join(output_dir, Ecto.UUID.generate() <> ".log")
    File.write!(old_log, "retained compiler output")
    File.touch!(old_log, System.os_time(:second) - 2 * 24 * 60 * 60)

    assert :idle =
             BuildWorker.run_once(context.queue, context.artifacts, context.builds,
               output_retention_ms: 24 * 60 * 60 * 1000
             )

    refute File.exists?(old_log)
  end

  test "creates durable Mix cache paths outside disposable job workspaces", context do
    assert :idle =
             BuildWorker.run_once(context.queue, context.artifacts, context.builds,
               build_fun: fn _request, _workspace -> flunk("no request should run") end
             )

    cache = BuildWorker.cache_paths(context.builds)

    assert File.dir?(cache.build)
    assert File.dir?(cache.deps)
    refute String.starts_with?(cache.build, Path.join(context.builds, "jobs"))
  end

  test "seeds the durable Mix cache from the pinned builder image once", context do
    source = Path.join(context.builds, "image")
    File.mkdir_p!(Path.join([source, "_build", "prod", "lib", "sample"]))
    File.mkdir_p!(Path.join([source, "deps", "sample"]))
    File.write!(Path.join([source, "_build", "prod", "lib", "sample", "sample.app"]), "app")
    File.write!(Path.join([source, "deps", "sample", "mix.exs"]), "dep")

    assert :idle = BuildWorker.run_once(context.queue, context.artifacts, context.builds)
    assert :ok = BuildWorker.seed_cache!(context.builds, source)

    cache = BuildWorker.cache_paths(context.builds)
    assert File.read!(Path.join([cache.build, "lib", "sample", "sample.app"])) == "app"
    assert File.read!(Path.join([cache.deps, "sample", "mix.exs"])) == "dep"

    File.write!(Path.join([source, "deps", "sample", "mix.exs"]), "changed")
    assert :ok = BuildWorker.seed_cache!(context.builds, source)
    assert File.read!(Path.join([cache.deps, "sample", "mix.exs"])) == "dep"
  end

  test "classifies nonembedded release-private files as structural" do
    assert BuildWorker.classify_source_paths(["priv/docs/cli-api.md"]) == []

    assert BuildWorker.classify_source_paths([
             "priv/programs/sarah/program.md",
             "priv/static/app.css",
             "priv/repo/migrations/20260822000000_add_example.exs"
           ]) == ["assets_changed", "migration_changed", "release_priv_changed"]
  end

  test "expired request IDs cannot be revived by a later attempt", context do
    expired_id = Ecto.UUID.generate()
    fresh_id = Ecto.UUID.generate()
    expired = request(expired_id, nil, DateTime.add(DateTime.utc_now(), -1, :second))
    write_request!(context.queue, expired)

    assert :processed =
             BuildWorker.run_once(context.queue, context.artifacts, context.builds,
               build_fun: fn _request, _workspace -> flunk("expired request reached compiler") end
             )

    expired_response = read_response!(context.queue, expired_id)
    assert expired_response["status"] == "error"
    assert expired_response["error_code"] == "request_expired"

    baseline = ArtifactFixtures.create!(@repo, String.duplicate("b", 40), []).manifest
    write_request!(context.queue, request(fresh_id, baseline))
    [{module, binary}] = Code.compile_string("defmodule OpenAgents.Scratch.FreshAttempt do\nend")
    :code.purge(module)
    :code.delete(module)

    build_fun = fn request, _workspace ->
      assert request["build_id"] == fresh_id

      {:ok, [%{module: Atom.to_string(module), binary: binary}],
       BuildArtifact.current_toolchain(), [], "ok"}
    end

    assert :processed =
             BuildWorker.run_once(context.queue, context.artifacts, context.builds,
               build_fun: build_fun
             )

    fresh_response = read_response!(context.queue, fresh_id)
    assert fresh_response["status"] == "ok"
    assert fresh_response["build_id"] != expired_response["build_id"]
  end

  defp request(build_id, baseline, expires_at \\ DateTime.add(DateTime.utc_now(), 300, :second)) do
    BuildProtocol.request!(%{
      build_id: build_id,
      repo: @repo,
      source_sha: @sha,
      target_id: Ecto.UUID.generate(),
      repo_url: "http://forge.internal/git/openagents.com.git",
      baseline_manifest: baseline,
      expires_at: DateTime.to_iso8601(expires_at)
    })
  end

  defp write_request!(queue, request) do
    {:ok, encoded} = BuildProtocol.encode_request(request)
    path = Path.join([queue, "requests", request["build_id"] <> ".json"])
    :ok = BuildProtocol.atomic_write(path, encoded)
  end

  defp read_response!(queue, build_id) do
    bytes = File.read!(Path.join([queue, "responses", build_id <> ".json"]))
    {:ok, response} = BuildProtocol.decode_response(bytes)
    response
  end
end
