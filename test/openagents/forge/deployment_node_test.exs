defmodule OpenAgents.Forge.DeploymentNodeTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.ArtifactFixtures
  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.BuildProtocol
  alias OpenAgents.Forge.DeploymentNode
  alias OpenAgents.Forge.Target

  setup do
    base = Path.join(System.tmp_dir!(), "deployment-node-#{System.unique_integer([:positive])}")
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_allowlist = Application.get_env(:openagents, :forge_hot_load_allowlist)
    previous_state = :sys.get_state(DeploymentNode)
    previous_persisted = :persistent_term.get({DeploymentNode, :state}, :missing)

    Application.put_env(:openagents, :forge_data_dir, base)
    Application.put_env(:openagents, :forge_hot_load_allowlist, ["OpenAgents.Scratch."])
    reset_participant()

    on_exit(fn ->
      :sys.replace_state(DeploymentNode, fn _state -> previous_state end)
      restore_persistent(previous_persisted)

      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_hot_load_allowlist, previous_allowlist)
      :persistent_term.erase({OpenAgents.Forge.BootConverge, :state})
      File.rm_rf(base)
    end)

    :ok
  end

  test "tokens fence prepare, apply, verify, commit, and readiness" do
    fixture = versions("TokenFence")
    request = request(fixture)

    assert {:ok, %{"token" => token, "prior" => [prior]}} =
             DeploymentNode.prepare(request)

    assert prior["sha256"] == BuildArtifact.digest(fixture.prior_binary)
    refute DeploymentNode.health()["ready"]

    assert {:error, :unknown_or_expired_token} =
             DeploymentNode.apply_candidate(request.deployment_id, "wrong-token")

    assert {:ok, %{"phase" => "applied"}} =
             DeploymentNode.apply_candidate(request.deployment_id, token)

    assert fixture.module.revision() == "candidate"

    assert {:ok, %{"deployment_ready" => true, "revision" => revision}} =
             DeploymentNode.verify_candidate(request.deployment_id, token)

    assert revision == request.sha
    assert {:ok, %{"phase" => "committed"}} = DeploymentNode.commit(request.deployment_id, token)
    refute DeploymentNode.health()["ready"]

    assert {:ok, %{"phase" => "live"}} =
             DeploymentNode.finalize(request.deployment_id, token)

    assert DeploymentNode.health()["ready"]
    assert DeploymentNode.health()["revision"] == request.sha
  end

  test "rollback restores and verifies exact prior object code" do
    fixture = versions("ExactRollback")
    request = request(fixture)
    prior_digest = BuildArtifact.digest(fixture.prior_binary)

    assert {:ok, %{"token" => token}} = DeploymentNode.prepare(request)
    assert {:ok, _response} = DeploymentNode.apply_candidate(request.deployment_id, token)
    assert {:ok, _response} = DeploymentNode.verify_candidate(request.deployment_id, token)
    assert fixture.module.revision() == "candidate"

    assert {:ok, %{"restored" => true}} = DeploymentNode.rollback(request.deployment_id, token)
    assert fixture.module.revision() == "prior"

    assert {module, binary, _file} = :code.get_object_code(fixture.module)
    assert module == fixture.module
    assert BuildArtifact.digest(binary) == prior_digest
    assert DeploymentNode.health()["ready"]
  end

  test "an expired token restores applied code before removing the transaction" do
    fixture = versions("ExpiredToken")
    request = request(fixture)

    assert {:ok, %{"token" => token}} = DeploymentNode.prepare(request)
    assert {:ok, _response} = DeploymentNode.apply_candidate(request.deployment_id, token)
    assert fixture.module.revision() == "candidate"

    expire_token(token)

    send(DeploymentNode, :sweep_expired)
    _state = :sys.get_state(DeploymentNode)

    assert fixture.module.revision() == "prior"
    assert DeploymentNode.health()["ready"]

    assert {:error, :unknown_or_expired_token} =
             DeploymentNode.verify_candidate(request.deployment_id, token)
  end

  test "an expired committed token follows immutable live database authority" do
    fixture = versions("CommittedToken")
    request = request(fixture)

    %Target{id: request.target_id}
    |> Target.changeset(%{
      repo: request.repo,
      sha: request.sha,
      promoted_by: "operator:test",
      status: "live",
      details: %{
        "deployment_id" => request.deployment_id,
        "artifact_digest" => request.artifact_digest
      }
    })
    |> Repo.insert!()

    assert {:ok, %{"token" => token}} = DeploymentNode.prepare(request)
    assert {:ok, _response} = DeploymentNode.apply_candidate(request.deployment_id, token)
    assert {:ok, _response} = DeploymentNode.verify_candidate(request.deployment_id, token)
    assert {:ok, _response} = DeploymentNode.commit(request.deployment_id, token)

    expire_token(token)
    send(DeploymentNode, :sweep_expired)
    _state = :sys.get_state(DeploymentNode)

    assert fixture.module.revision() == "candidate"
    assert DeploymentNode.health()["ready"]
    assert DeploymentNode.health()["revision"] == request.sha

    assert {:error, :unknown_or_expired_token} =
             DeploymentNode.rollback(request.deployment_id, token)
  end

  test "an expired committed token rolls back when durable authority refused it" do
    fixture = versions("RejectedCommit")
    request = request(fixture)

    assert {:ok, %{"token" => token}} = DeploymentNode.prepare(request)
    assert {:ok, _response} = DeploymentNode.apply_candidate(request.deployment_id, token)
    assert {:ok, _response} = DeploymentNode.verify_candidate(request.deployment_id, token)
    assert {:ok, _response} = DeploymentNode.commit(request.deployment_id, token)

    expire_token(token)
    send(DeploymentNode, :sweep_expired)
    _state = :sys.get_state(DeploymentNode)

    assert fixture.module.revision() == "prior"
    assert DeploymentNode.health()["ready"]
  end

  test "an in-flight database commit extends a committed token without serving" do
    fixture = versions("PendingCommit")
    request = request(fixture)

    target =
      %Target{id: request.target_id}
      |> Target.changeset(%{
        repo: request.repo,
        sha: request.sha,
        promoted_by: "operator:test",
        status: "deploying"
      })
      |> Repo.insert!()

    assert {:ok, %{"token" => token}} = DeploymentNode.prepare(request)
    assert {:ok, _response} = DeploymentNode.apply_candidate(request.deployment_id, token)
    assert {:ok, _response} = DeploymentNode.verify_candidate(request.deployment_id, token)
    assert {:ok, _response} = DeploymentNode.commit(request.deployment_id, token)

    expire_token(token)
    send(DeploymentNode, :sweep_expired)
    _state = :sys.get_state(DeploymentNode)

    assert fixture.module.revision() == "candidate"
    refute DeploymentNode.health()["ready"]

    target
    |> Target.status_changeset("live", %{
      "deployment_id" => request.deployment_id,
      "artifact_digest" => request.artifact_digest
    })
    |> Repo.update!()

    expire_token(token)
    send(DeploymentNode, :sweep_expired)
    _state = :sys.get_state(DeploymentNode)

    assert DeploymentNode.health()["ready"]
    assert fixture.module.revision() == "candidate"
  end

  test "a supervised participant restart preserves the rollback fence" do
    fixture = versions("ParticipantRestart")
    request = request(fixture)

    assert {:ok, %{"token" => token}} = DeploymentNode.prepare(request)
    assert {:ok, _response} = DeploymentNode.apply_candidate(request.deployment_id, token)
    assert fixture.module.revision() == "candidate"

    assert :ok = Supervisor.terminate_child(OpenAgents.Supervisor, DeploymentNode)
    refute DeploymentNode.health()["ready"]
    refute DeploymentNode.health()["participant_ready"]
    assert {:ok, _pid} = Supervisor.restart_child(OpenAgents.Supervisor, DeploymentNode)
    refute DeploymentNode.health()["ready"]

    assert {:ok, %{"restored" => true}} =
             DeploymentNode.rollback(request.deployment_id, token)

    assert fixture.module.revision() == "prior"
    assert DeploymentNode.health()["ready"]
  end

  defp versions(suffix) do
    name = "OpenAgents.Scratch.#{suffix}#{System.unique_integer([:positive])}"
    module = Module.concat([name])
    prior_binary = compile(name, "prior")
    unload(module)
    candidate_binary = compile(name, "candidate")

    prior_dir =
      Path.join(System.tmp_dir!(), "deployment-prior-#{System.unique_integer([:positive])}")

    File.mkdir_p!(prior_dir)
    File.write!(Path.join(prior_dir, Atom.to_string(module) <> ".beam"), prior_binary)
    true = :code.add_patha(to_charlist(prior_dir))
    unload(module)
    assert {:module, ^module} = :code.load_file(module)

    on_exit(fn ->
      unload(module)
      :code.del_path(to_charlist(prior_dir))
      File.rm_rf(prior_dir)
    end)

    sha = random_sha()
    built = ArtifactFixtures.create!("openagents.com", sha, [{name, candidate_binary}])

    %{
      module: module,
      prior_binary: prior_binary,
      built: built,
      sha: sha
    }
  end

  defp request(fixture) do
    manifest_digest =
      fixture.built.manifest
      |> BuildProtocol.canonical_json()
      |> BuildArtifact.digest()

    %{
      artifact_bytes: fixture.built.bytes,
      artifact_digest: fixture.built.digest,
      build_id: fixture.built.build_id,
      deployment_id: Ecto.UUID.generate(),
      expected_nodes: [to_string(Node.self())],
      manifest_digest: manifest_digest,
      repo: "openagents.com",
      sha: fixture.sha,
      target_id: Ecto.UUID.generate()
    }
  end

  defp compile(name, revision) do
    [{_module, binary}] =
      Code.compile_string("defmodule #{name} do\n  def revision, do: #{inspect(revision)}\nend")

    binary
  end

  defp random_sha, do: 20 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp reset_participant do
    :persistent_term.erase({DeploymentNode, :state})

    :sys.replace_state(DeploymentNode, fn state ->
      %{state | transactions: %{}, live: nil, divergence: nil, faults: %{}, notify: nil}
    end)
  end

  defp expire_token(token) do
    :sys.replace_state(DeploymentNode, fn state ->
      update_in(
        state,
        [:transactions, token],
        &%{&1 | expires_at: System.monotonic_time(:millisecond) - 1}
      )
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)

  defp restore_persistent(:missing), do: :persistent_term.erase({DeploymentNode, :state})

  defp restore_persistent(state),
    do: :persistent_term.put({DeploymentNode, :state}, state)
end
