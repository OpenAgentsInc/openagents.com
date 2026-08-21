defmodule OpenAgents.Forge.BuildArtifactTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.BuildProtocol

  @repo "openagents.com"
  @sha String.duplicate("a", 40)
  @next_sha String.duplicate("b", 40)

  test "the JSON build protocol rejects executable, unknown, stale, and mismatched fields" do
    build_id = Ecto.UUID.generate()
    target_id = Ecto.UUID.generate()

    request =
      BuildProtocol.request!(%{
        build_id: build_id,
        repo: @repo,
        source_sha: @sha,
        target_id: target_id,
        repo_url: "http://forge.internal/git/openagents.com.git",
        baseline_manifest: nil,
        expires_at: DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.to_iso8601()
      })

    assert {:ok, encoded} = BuildProtocol.encode_request(request)
    assert {:ok, ^request} = BuildProtocol.decode_request(encoded)
    refute encoded =~ "SHA="
    refute encoded =~ "source "

    assert {:error, :unexpected_fields} =
             request
             |> Map.put("shell", "$(touch /tmp/owned)")
             |> BuildProtocol.validate_request()

    assert {:error, :invalid_repo_url} =
             request
             |> Map.put("repo_url", "https://token@forge.internal/git/openagents.com.git")
             |> BuildProtocol.validate_request()

    response =
      BuildProtocol.ok_response(build_id, %{
        artifact_digest: String.duplicate("f", 64),
        artifact_ref: "artifacts/#{String.duplicate("f", 64)}.tar",
        output_digest: String.duplicate("e", 64),
        output_ref: "output/#{build_id}.log",
        duration_ms: 42
      })

    assert {:ok, response_json} = BuildProtocol.encode_response(response)
    assert {:ok, ^response} = BuildProtocol.decode_response(response_json)

    assert {:error, {:invalid_uuid, :build_id}} =
             response
             |> Map.put("build_id", "not-a-build-id")
             |> BuildProtocol.validate_response()
  end

  test "protocol writes queue files by atomic same-directory rename" do
    dir = Path.join(System.tmp_dir!(), "build-protocol-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "request.json")
    on_exit(fn -> File.rm_rf(dir) end)

    assert :ok = BuildProtocol.atomic_write(path, "{}")
    assert File.read!(path) == "{}"
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert {:ok, ["request.json"]} = File.ls(dir)
    assert {:error, :destination_exists} = BuildProtocol.atomic_write(path, "replacement")
    assert File.read!(path) == "{}"
  end

  test "artifacts are reproducible and bind manifest, digest, changes, and BEAM identity" do
    baseline_id = Ecto.UUID.generate()
    candidate_id = Ecto.UUID.generate()
    toolchain = BuildArtifact.current_toolchain()

    baseline_beams = [compile_beam("ReproducibleProbe", 1)]

    assert {:ok, baseline} =
             BuildArtifact.pack(@repo, @sha, baseline_id, baseline_beams, toolchain: toolchain)

    candidate_beams = [compile_beam("ReproducibleProbe", 2), compile_beam("AddedProbe", 3)]

    opts = [baseline_manifest: baseline.manifest, toolchain: toolchain]

    assert {:ok, candidate} =
             BuildArtifact.pack(@repo, @next_sha, candidate_id, candidate_beams, opts)

    assert {:ok, repeated} =
             BuildArtifact.pack(@repo, @next_sha, candidate_id, candidate_beams, opts)

    assert repeated.bytes == candidate.bytes
    assert repeated.digest == candidate.digest
    assert candidate.manifest["classification"] == "direct_candidate"
    assert candidate.manifest["changes"]["added"] == ["Elixir.OpenAgents.Scratch.AddedProbe"]

    assert candidate.manifest["changes"]["changed"] == [
             "Elixir.OpenAgents.Scratch.ReproducibleProbe"
           ]

    assert candidate.manifest["changes"]["deleted"] == []

    assert {:ok, verified} =
             BuildArtifact.verify(candidate.bytes,
               digest: candidate.digest,
               repo: @repo,
               source_sha: @next_sha,
               build_id: candidate_id
             )

    assert verified.modules == [
             "Elixir.OpenAgents.Scratch.AddedProbe",
             "Elixir.OpenAgents.Scratch.ReproducibleProbe"
           ]

    assert {:error, :artifact_digest_mismatch} =
             BuildArtifact.verify(candidate.bytes, digest: String.duplicate("0", 64))
  end

  test "deletions and toolchain drift route away from direct loading" do
    toolchain = BuildArtifact.current_toolchain()

    assert {:ok, baseline} =
             BuildArtifact.pack(
               @repo,
               @sha,
               Ecto.UUID.generate(),
               [compile_beam("KeepProbe", 1), compile_beam("DeleteProbe", 1)],
               toolchain: toolchain
             )

    drifted = Map.put(toolchain, "otp", "different")

    assert {:ok, candidate} =
             BuildArtifact.pack(
               @repo,
               @next_sha,
               Ecto.UUID.generate(),
               [compile_beam("KeepProbe", 1)],
               baseline_manifest: baseline.manifest,
               toolchain: drifted,
               structural_reasons: ["config_changed", "nif_changed"]
             )

    assert candidate.manifest["classification"] == "needs_rolling_replace"

    assert candidate.manifest["structural_reasons"] == [
             "config_changed",
             "module_deletion",
             "nif_changed",
             "toolchain_otp_changed"
           ]

    assert candidate.manifest["changes"]["deleted"] == [
             "Elixir.OpenAgents.Scratch.DeleteProbe"
           ]
  end

  test "malformed entry paths and mismatched internal module names fail before atomization" do
    beam = compile_beam("IdentityProbe", 1)
    build_id = Ecto.UUID.generate()

    assert {:ok, artifact} =
             BuildArtifact.pack(@repo, @sha, build_id, [beam],
               toolchain: BuildArtifact.current_toolchain()
             )

    {:ok, entries} = :erl_tar.extract({:binary, artifact.bytes}, [:memory])

    replaced =
      Enum.map(entries, fn
        {~c"beams/Elixir.OpenAgents.Scratch.IdentityProbe.beam", binary} ->
          {~c"beams/Elixir.OpenAgents.Scratch.Impostor.beam", binary}

        entry ->
          entry
      end)

    tampered = tar_bytes(replaced)
    assert {:error, :undeclared_module} = BuildArtifact.verify(tampered)

    traversal =
      Enum.map(entries, fn
        {~c"beams/Elixir.OpenAgents.Scratch.IdentityProbe.beam", binary} ->
          {~c"../escape.beam", binary}

        entry ->
          entry
      end)

    assert {:error, :invalid_artifact_entry} = BuildArtifact.verify(tar_bytes(traversal))
  end

  test "application-owned release module namespaces are admitted" do
    build_id = Ecto.UUID.generate()

    beams = [
      loaded_beam(OpenAgents),
      loaded_beam(OpenAgentsWeb),
      loaded_beam(Inspect.OpenAgents.Accounts.User),
      loaded_beam(Mix.Tasks.Openagents.Config.Readiness)
    ]

    assert {:ok, artifact} =
             BuildArtifact.pack(@repo, @sha, build_id, beams,
               toolchain: BuildArtifact.current_toolchain()
             )

    assert artifact.manifest["changes"]["added"] ==
             Enum.sort([
               "Elixir.Inspect.OpenAgents.Accounts.User",
               "Elixir.Mix.Tasks.Openagents.Config.Readiness",
               "Elixir.OpenAgents",
               "Elixir.OpenAgentsWeb"
             ])
  end

  defp compile_beam(suffix, value) do
    module = "OpenAgents.Scratch.#{suffix}"

    [{atom, binary}] =
      Code.compile_string("defmodule #{module} do\n def value, do: #{value}\nend")

    :code.purge(atom)
    :code.delete(atom)
    %{module: "Elixir." <> module, binary: binary}
  end

  defp loaded_beam(module) do
    assert {:module, ^module} = Code.ensure_loaded(module)
    {^module, binary, _path} = :code.get_object_code(module)
    %{module: Atom.to_string(module), binary: binary}
  end

  defp tar_bytes(entries) do
    path = Path.join(System.tmp_dir!(), "artifact-test-#{System.unique_integer([:positive])}.tar")
    :ok = :erl_tar.create(String.to_charlist(path), entries)
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end
end
