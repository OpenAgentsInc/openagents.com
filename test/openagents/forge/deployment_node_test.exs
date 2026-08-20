defmodule OpenAgents.Forge.DeploymentNodeTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.ArtifactFixtures
  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.BuildProtocol
  alias OpenAgents.Forge.Deployment
  alias OpenAgents.Forge.DeploymentNode
  alias OpenAgents.Forge.Target

  setup do
    base = Path.join(System.tmp_dir!(), "deployment-node-#{System.unique_integer([:positive])}")
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_allowlist = Application.get_env(:openagents, :forge_hot_load_allowlist)
    previous_expected = Application.get_env(:openagents, :forge_expected_fleet_size)
    previous_state = :sys.get_state(DeploymentNode)
    previous_persisted = :persistent_term.get({DeploymentNode, :state}, :missing)

    Application.put_env(:openagents, :forge_data_dir, base)
    Application.put_env(:openagents, :forge_hot_load_allowlist, ["OpenAgents.Scratch."])
    Application.put_env(:openagents, :forge_expected_fleet_size, 1)
    reset_participant()

    on_exit(fn ->
      :sys.replace_state(DeploymentNode, fn _state -> previous_state end)
      restore_persistent(previous_persisted)

      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_hot_load_allowlist, previous_allowlist)
      restore_env(:forge_expected_fleet_size, previous_expected)
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

  test "rollback removes a candidate whose module was absent before prepare" do
    fixture = absent_version("AbsentRollback")
    request = request(fixture)

    refute Code.ensure_loaded?(fixture.module)

    assert {:ok, %{"token" => token, "prior" => [prior]}} =
             DeploymentNode.prepare(request)

    assert prior == %{"module" => to_string(fixture.module), "state" => "absent"}
    assert {:ok, _response} = DeploymentNode.apply_candidate(request.deployment_id, token)
    assert fixture.module.revision() == "candidate"

    assert {:ok, %{"restored" => true}} = DeploymentNode.rollback(request.deployment_id, token)
    refute Code.ensure_loaded?(fixture.module)
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

  test "prepare rejects every malformed request identity before changing state" do
    fixture = versions("InvalidRequest")
    valid = request(fixture)

    invalid_requests = [
      {:invalid_deployment_request, :not_a_map},
      {:unexpected_deployment_fields, Map.delete(valid, :repo)},
      {:invalid_deployment_id, %{valid | deployment_id: "invalid"}},
      {:invalid_target_id, %{valid | target_id: "invalid"}},
      {:invalid_build_id, %{valid | build_id: "invalid"}},
      {:invalid_source_sha, %{valid | sha: "invalid"}},
      {:invalid_artifact_digest, %{valid | artifact_digest: "invalid"}},
      {:invalid_manifest_digest, %{valid | manifest_digest: "invalid"}},
      {:invalid_repo, %{valid | repo: nil}},
      {:invalid_artifact, %{valid | artifact_bytes: nil}},
      {:invalid_expected_nodes, %{valid | expected_nodes: []}}
    ]

    for {reason, invalid} <- invalid_requests do
      assert {:error, ^reason} = DeploymentNode.prepare(invalid)
    end

    assert {:error, :manifest_digest_mismatch} =
             valid
             |> Map.put(:manifest_digest, String.duplicate("0", 64))
             |> DeploymentNode.prepare()

    assert DeploymentNode.health()["ready"]
  end

  test "prepare independently enforces classification, allowlist, and runtime toolchain" do
    direct = absent_version("OffAllowlist")
    Application.put_env(:openagents, :forge_hot_load_allowlist, [])
    assert {:error, :module_not_allowlisted} = DeploymentNode.prepare(request(direct))

    Application.put_env(:openagents, :forge_hot_load_allowlist, ["OpenAgents.Scratch."])

    structural =
      absent_version("StructuralArtifact", structural_reasons: ["config_changed"])

    assert {:error, :artifact_not_direct} = DeploymentNode.prepare(request(structural))

    mismatched_toolchain =
      BuildArtifact.current_toolchain()
      |> Map.put("otp", "0")

    wrong_runtime = absent_version("WrongRuntime", toolchain: mismatched_toolchain)

    assert {:error, :runtime_toolchain_mismatch} =
             DeploymentNode.prepare(request(wrong_runtime))
  end

  test "fault injection is bounded and participant phase notifications are content-free" do
    fixture = absent_version("FaultBoundary")
    request = request(fixture)
    test_pid = self()

    :sys.replace_state(DeploymentNode, fn state ->
      %{state | faults: %{prepare: :invalid_fault}}
    end)

    assert {:error, {:invalid_injected_fault, :invalid_fault}} =
             DeploymentNode.prepare(request)

    :sys.replace_state(DeploymentNode, fn state ->
      %{state | faults: %{prepare: :timeout}, fault_timeout_ms: 0}
    end)

    assert {:error, :injected_timeout} = DeploymentNode.prepare(request)

    :sys.replace_state(DeploymentNode, fn state ->
      %{state | faults: %{}, notify: test_pid}
    end)

    assert {:ok, %{"token" => token}} = DeploymentNode.prepare(request)
    assert_receive {:forge_deployment_node, _node, :prepared}

    assert {:ok, %{"restored" => true}} = DeploymentNode.rollback(request.deployment_id, token)
  end

  test "phase ordering and deployment identity are fenced by the token" do
    fixture = versions("PhaseOrdering")
    request = request(fixture)

    assert {:ok, %{"token" => token}} = DeploymentNode.prepare(request)

    assert {:error, :deployment_token_mismatch} =
             DeploymentNode.apply_candidate(Ecto.UUID.generate(), token)

    assert {:error, {:invalid_phase, :prepared, :verify}} =
             DeploymentNode.verify_candidate(request.deployment_id, token)

    assert {:error, {:invalid_phase, :prepared, :commit}} =
             DeploymentNode.commit(request.deployment_id, token)

    assert {:error, {:invalid_phase, :prepared, :finalize}} =
             DeploymentNode.finalize(request.deployment_id, token)

    assert {:ok, _response} = DeploymentNode.apply_candidate(request.deployment_id, token)

    assert {:error, {:invalid_phase, :applied, :apply}} =
             DeploymentNode.apply_candidate(request.deployment_id, token)

    assert {:ok, _response} = DeploymentNode.verify_candidate(request.deployment_id, token)
    assert {:ok, _response} = DeploymentNode.verify_candidate(request.deployment_id, token)
    assert {:ok, %{"restored" => true}} = DeploymentNode.rollback(request.deployment_id, token)

    send(DeploymentNode, :irrelevant_message)
    _state = :sys.get_state(DeploymentNode)
    assert DeploymentNode.health()["ready"]
  end

  test "candidate verification failure restores the exact prior object code" do
    fixture = versions("VerificationFailure")
    request = request(fixture)

    assert {:ok, %{"token" => token}} = DeploymentNode.prepare(request)
    assert {:ok, _response} = DeploymentNode.apply_candidate(request.deployment_id, token)
    unload(fixture.module)

    assert {:error, {:verification_failed, :candidate_object_code_mismatch}} =
             DeploymentNode.verify_candidate(request.deployment_id, token)

    assert fixture.module.revision() == "prior"
    assert DeploymentNode.health()["ready"]
  end

  test "candidate smoke-contract failure removes a previously absent module" do
    fixture = invalid_smoke_version("SmokeFailure")
    request = request(fixture)

    assert {:ok, %{"token" => token}} = DeploymentNode.prepare(request)
    assert {:ok, _response} = DeploymentNode.apply_candidate(request.deployment_id, token)

    assert {:error, {:verification_failed, :candidate_smoke_failed}} =
             DeploymentNode.verify_candidate(request.deployment_id, token)

    refute Code.ensure_loaded?(fixture.module)
    assert DeploymentNode.health()["ready"]

    assert {:error, {:verification_failed, :candidate_smoke_failed}} =
             DeploymentNode.install_artifact(request)

    refute Code.ensure_loaded?(fixture.module)
    assert DeploymentNode.health()["ready"]
  end

  test "boot installation is exclusive with a transaction and then completes locally" do
    first = versions("InstallExclusive")
    second = versions("InstallAfterRollback")
    first_request = request(first)
    second_request = request(second)

    assert {:ok, %{"token" => token}} = DeploymentNode.prepare(first_request)
    assert {:error, :deployment_in_progress} = DeploymentNode.install_artifact(second_request)

    assert {:ok, %{"restored" => true}} =
             DeploymentNode.rollback(first_request.deployment_id, token)

    assert {:ok, %{"phase" => "live", "revision" => revision}} =
             DeploymentNode.install_artifact(second_request)

    assert revision == second.sha
    assert second.module.revision() == "candidate"
    assert DeploymentNode.health()["ready"]
  end

  test "participant enforces its bounded transaction capacity" do
    fixture = versions("BoundedCapacity")
    request = request(fixture)

    tokens =
      for _index <- 1..4 do
        assert {:ok, %{"token" => token}} = DeploymentNode.prepare(request)
        token
      end

    assert {:error, :deployment_capacity_reached} = DeploymentNode.prepare(request)

    for token <- tokens do
      assert {:ok, %{"restored" => true}} =
               DeploymentNode.rollback(request.deployment_id, token)
    end

    assert DeploymentNode.health()["ready"]
  end

  test "single-node coordinator rolls back failures at every transaction boundary" do
    fixture = versions("CoordinatorFailures")

    for {fault, expected_code, expected_result} <- [
          {:prepare, "prepare_failed", "failed"},
          {:apply, "canary_apply_failed", "failed"},
          {:verify, "canary_verify_failed", "reverted"},
          {:commit, "fleet_commit_failed", "reverted"}
        ] do
      set_faults(%{fault => :error})

      assert {:error, outcome} = run_deployment(fixture)
      assert outcome.error_code == expected_code
      assert outcome.result == expected_result

      set_faults(%{})
      assert fixture.module.revision() == "prior"
      assert DeploymentNode.health()["ready"]
    end
  end

  test "coordinator exposes finalize and explicit rollback failures without losing its fence" do
    fixture = versions("CoordinatorFinalization")

    assert {:ok, session} = run_deployment(fixture)
    set_faults(%{finalize: :error})

    assert {:error, {:finalize_failed, node_results}} = Deployment.finalize(session)
    assert node_results[to_string(Node.self())] == "injected_failure"
    refute DeploymentNode.health()["ready"]

    set_faults(%{})
    assert {:ok, restored} = Deployment.rollback(session)
    assert restored[to_string(Node.self())] == "restored"
    assert fixture.module.revision() == "prior"

    assert {:ok, second_session} = run_deployment(fixture)
    set_faults(%{rollback: :error})
    assert {:error, rollback_results} = Deployment.rollback(second_session)
    assert rollback_results[to_string(Node.self())] == "injected_failure"

    set_faults(%{})
    assert {:ok, _restored} = Deployment.rollback(second_session)
    assert DeploymentNode.health()["ready"]
  end

  test "coordinator refuses missing, undersized, and unready fleet snapshots" do
    fixture = versions("CoordinatorSnapshot")

    Application.put_env(:openagents, :forge_expected_fleet_size, 0)

    assert {:error, empty} =
             run_deployment(fixture, members: fn -> [] end)

    assert empty.error_code == "empty_fleet"

    Application.put_env(:openagents, :forge_expected_fleet_size, 2)
    assert {:error, undersized} = run_deployment(fixture)
    assert undersized.error_code == "fleet_size_mismatch"

    Application.put_env(:openagents, :forge_expected_fleet_size, 1)

    :sys.replace_state(DeploymentNode, fn state ->
      %{state | divergence: "test_divergence"}
    end)

    assert {:error, unready} = run_deployment(fixture)
    assert unready.error_code == "fleet_not_ready"
    assert unready.node_results[to_string(Node.self())] =~ "unhealthy"
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

  defp absent_version(suffix, opts \\ []) do
    name = "OpenAgents.Scratch.#{suffix}#{System.unique_integer([:positive])}"
    module = Module.concat([name])
    candidate_binary = compile(name, "candidate")
    unload(module)

    on_exit(fn -> unload(module) end)

    sha = random_sha()
    built = ArtifactFixtures.create!("openagents.com", sha, [{name, candidate_binary}], opts)

    %{module: module, built: built, sha: sha}
  end

  defp invalid_smoke_version(suffix) do
    name = "OpenAgents.Scratch.#{suffix}#{System.unique_integer([:positive])}"
    module = Module.concat([name])

    [{^module, candidate_binary}] =
      Code.compile_string("defmodule #{name} do\n  def revision, do: :invalid\nend")

    unload(module)
    on_exit(fn -> unload(module) end)

    sha = random_sha()
    built = ArtifactFixtures.create!("openagents.com", sha, [{name, candidate_binary}])

    %{module: module, built: built, sha: sha}
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

  defp run_deployment(fixture, opts \\ []) do
    {:ok, verified} =
      BuildArtifact.verify(fixture.built.bytes,
        digest: fixture.built.digest,
        repo: "openagents.com",
        source_sha: fixture.sha,
        build_id: fixture.built.build_id
      )

    build = %{
      repo: "openagents.com",
      sha: fixture.sha,
      target_id: Ecto.UUID.generate(),
      build_id: fixture.built.build_id,
      modules: verified.modules,
      manifest: fixture.built.manifest
    }

    Deployment.run(build, verified, fixture.built.bytes, opts)
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

  defp set_faults(faults) do
    :sys.replace_state(DeploymentNode, fn state -> %{state | faults: faults} end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)

  defp restore_persistent(:missing), do: :persistent_term.erase({DeploymentNode, :state})

  defp restore_persistent(state),
    do: :persistent_term.put({DeploymentNode, :state}, state)
end
