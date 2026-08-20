defmodule OpenAgents.Forge.DeploymentNode do
  @moduledoc """
  Per-node participant in a transactional direct deployment.

  A participant independently verifies the immutable artifact, snapshots the
  exact object code it would replace, and returns an expiring opaque token.
  Later phases must present that token and the deployment ID. The participant
  keeps external readiness false from prepare through commit. It restores and
  verifies the snapshot on any failed or expired transaction, and it remains
  out of readiness when exact restoration fails.
  """

  use GenServer

  alias OpenAgents.Forge.BootConverge
  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.BuildProtocol
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.Targets

  @default_timeout_ms 15_000
  @default_token_ttl_ms 120_000
  @maximum_transactions 4
  @sweep_interval_ms 1_000
  @state_key {__MODULE__, :state}
  @request_keys ~w(artifact_bytes artifact_digest build_id deployment_id expected_nodes manifest_digest repo sha target_id)a

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Prepare one verified deployment and return its expiring token."
  def prepare(request), do: call({:prepare, request})

  @doc "Apply the candidate associated with an expiring deployment token."
  def apply_candidate(deployment_id, token),
    do: call({:phase, :apply, deployment_id, token})

  @doc "Verify candidate object-code identity and the application revision."
  def verify_candidate(deployment_id, token),
    do: call({:phase, :verify, deployment_id, token})

  @doc "Commit a verified candidate while retaining the rollback fence."
  def commit(deployment_id, token), do: call({:phase, :commit, deployment_id, token})

  @doc "Release a fleet-committed candidate into external readiness."
  def finalize(deployment_id, token), do: call({:phase, :finalize, deployment_id, token})

  @doc "Restore and verify the exact predeployment object code."
  def rollback(deployment_id, token), do: call({:phase, :rollback, deployment_id, token})

  @doc "Install one boot-convergence artifact through the same local verifier."
  def install_artifact(request), do: call({:install_artifact, request}, timeout_ms() * 2)

  @doc "Return a bounded, content-free readiness report for this node."
  def health do
    case Process.whereis(__MODULE__) do
      nil -> unavailable_health()
      _pid -> call(:health)
    end
  catch
    :exit, _reason -> unavailable_health()
  end

  @doc false
  def deployment_health(repo, target_id), do: call({:deployment_health, repo, target_id})

  @impl true
  def init(opts) do
    Process.send_after(self(), :sweep_expired, @sweep_interval_ms)

    recovered =
      case :persistent_term.get(@state_key, nil) do
        %{schema: 1} = state -> state
        _missing_or_old -> %{transactions: %{}, live: nil, divergence: nil}
      end

    state =
      %{
        transactions: recovered.transactions,
        live: recovered.live,
        divergence: recovered.divergence,
        faults: Keyword.get(opts, :faults, %{}),
        fault_timeout_ms: Keyword.get(opts, :fault_timeout_ms, timeout_ms() * 2),
        notify: Keyword.get(opts, :notify)
      }

    {:ok, persist(state)}
  end

  @impl true
  def handle_call(:health, _from, state), do: {:reply, health_report(state), state}

  def handle_call({:deployment_health, repo, target_id}, _from, state) do
    boot_ready? = BootConverge.ready_for_deployment?(repo, target_id)
    {:reply, health_report(state, boot_ready?), state}
  end

  def handle_call({:prepare, request}, _from, state) do
    state = expire_transactions(state)

    with :ok <- run_fault(:prepare, state),
         :ok <- capacity_available(state),
         {:ok, transaction, response} <- prepare_transaction(request, state) do
      notify(state, :prepared)

      state = put_in(state, [:transactions, transaction.token], transaction)
      {:reply, {:ok, response}, persist(state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, persist(state)}
    end
  end

  def handle_call({:phase, phase, deployment_id, token}, _from, state) do
    state = expire_transactions(state)

    with :ok <- run_fault(phase, state),
         {:ok, transaction} <- fetch_transaction(state, deployment_id, token),
         {:ok, response, state} <- run_phase(phase, transaction, state) do
      notify(state, phase)
      {:reply, {:ok, response}, persist(state)}
    else
      {:error, reason, updated_state} -> {:reply, {:error, reason}, persist(updated_state)}
      {:error, reason} -> {:reply, {:error, reason}, persist(state)}
    end
  end

  def handle_call({:install_artifact, request}, _from, state) do
    state = expire_transactions(state)

    result =
      with :ok <- participant_idle(state),
           {:ok, transaction, _prepared} <- prepare_transaction(request, state),
           state = put_in(state, [:transactions, transaction.token], transaction),
           {:ok, _applied, state} <- run_phase(:apply, transaction, state),
           {:ok, _verified, state} <-
             run_phase(:verify, state.transactions[transaction.token], state),
           {:ok, _committed, state} <-
             run_phase(:commit, state.transactions[transaction.token], state),
           {:ok, finalized, state} <-
             run_phase(:finalize, state.transactions[transaction.token], state) do
        {:ok, finalized, state}
      else
        {:error, reason, failed_state} ->
          {:error, reason, rollback_install(request, failed_state)}

        {:error, reason} ->
          {:error, reason, state}
      end

    case result do
      {:ok, response, updated_state} -> {:reply, {:ok, response}, persist(updated_state)}
      {:error, reason, updated_state} -> {:reply, {:error, reason}, persist(updated_state)}
    end
  end

  @impl true
  def handle_info(:sweep_expired, state) do
    Process.send_after(self(), :sweep_expired, @sweep_interval_ms)
    {:noreply, state |> expire_transactions() |> persist()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp call(message, timeout \\ nil) do
    GenServer.call(__MODULE__, message, timeout || timeout_ms())
  end

  defp prepare_transaction(request, state) do
    with :ok <- validate_request(request),
         {:ok, verified} <-
           BuildArtifact.verify(request.artifact_bytes,
             digest: request.artifact_digest,
             repo: request.repo,
             source_sha: request.sha,
             build_id: request.build_id
           ),
         :ok <- verify_manifest_identity(verified, request),
         :ok <- verify_direct_candidate(verified),
         :ok <- verify_runtime_toolchain(verified.manifest["toolchain"]),
         :ok <- cache_artifact(request.artifact_bytes, request.artifact_digest),
         candidates = candidates(verified.beams),
         {:ok, prior} <- snapshot_prior(candidates, state.live) do
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      expires_in_ms = token_ttl_ms()

      transaction = %{
        deployment_id: request.deployment_id,
        target_id: request.target_id,
        repo: request.repo,
        sha: request.sha,
        artifact_digest: request.artifact_digest,
        manifest_digest: request.manifest_digest,
        manifest: verified.manifest,
        expected_nodes: request.expected_nodes,
        candidates: candidates,
        prior: prior,
        prior_live: state.live,
        prior_boot: BootConverge.state(),
        token: token,
        expires_at: monotonic_ms() + expires_in_ms,
        phase: :prepared
      }

      response = %{
        "token" => token,
        "artifact_digest" => request.artifact_digest,
        "manifest_digest" => request.manifest_digest,
        "prior" => prior_projection(prior),
        "expires_in_ms" => expires_in_ms
      }

      {:ok, transaction, response}
    end
  end

  defp run_phase(:apply, %{phase: :prepared} = transaction, state) do
    case load_candidates(transaction.candidates) do
      :ok ->
        updated = %{transaction | phase: :applied}
        {:ok, %{"phase" => "applied"}, put_transaction(state, updated)}

      {:error, reason} ->
        rollback_after_failure(transaction, state, {:apply_failed, reason})
    end
  end

  defp run_phase(:verify, %{phase: :applied} = transaction, state) do
    case verify_candidates(transaction) do
      :ok ->
        updated = %{transaction | phase: :verified}

        {:ok,
         %{
           "phase" => "verified",
           "revision" => transaction.sha,
           "application_version" => transaction.manifest["toolchain"]["application_version"],
           "deployment_ready" => true
         }, put_transaction(state, updated)}

      {:error, reason} ->
        rollback_after_failure(transaction, state, {:verification_failed, reason})
    end
  end

  defp run_phase(:verify, %{phase: :verified} = transaction, state) do
    case verify_candidates(transaction) do
      :ok ->
        {:ok,
         %{
           "phase" => "verified",
           "revision" => transaction.sha,
           "application_version" => transaction.manifest["toolchain"]["application_version"],
           "deployment_ready" => true
         }, state}

      {:error, reason} ->
        rollback_after_failure(transaction, state, {:verification_failed, reason})
    end
  end

  defp run_phase(:commit, %{phase: :verified} = transaction, state) do
    updated = %{transaction | phase: :committed}
    state = state |> put_transaction(updated) |> Map.put(:live, live_identity(transaction))
    {:ok, %{"phase" => "committed", "revision" => transaction.sha}, state}
  end

  defp run_phase(:finalize, %{phase: :committed} = transaction, state) do
    state = %{
      state
      | transactions: Map.delete(state.transactions, transaction.token),
        divergence: nil
    }

    BootConverge.mark_converged(live_identity(transaction))

    {:ok,
     %{
       "phase" => "live",
       "revision" => transaction.sha,
       "artifact_digest" => transaction.artifact_digest
     }, state}
  end

  defp run_phase(:rollback, transaction, state) do
    case restore_and_verify(transaction.prior) do
      :ok ->
        state = %{
          state
          | transactions: Map.delete(state.transactions, transaction.token),
            live: transaction.prior_live,
            divergence: nil
        }

        BootConverge.restore_state(transaction.prior_boot)

        {:ok, %{"phase" => "restored", "restored" => true}, state}

      {:error, reason} ->
        state = %{state | divergence: "rollback_unverified"}
        {:error, {:rollback_failed, reason}, state}
    end
  end

  defp run_phase(phase, transaction, _state) do
    {:error, {:invalid_phase, transaction.phase, phase}}
  end

  defp rollback_after_failure(transaction, state, reason) do
    case restore_and_verify(transaction.prior) do
      :ok ->
        state = %{
          state
          | transactions: Map.delete(state.transactions, transaction.token),
            live: transaction.prior_live
        }

        {:error, reason, state}

      {:error, rollback_reason} ->
        state = %{state | divergence: "rollback_unverified"}
        {:error, {:rollback_failed, rollback_reason}, state}
    end
  end

  defp rollback_install(request, state) do
    case Enum.find(state.transactions, fn {_token, transaction} ->
           transaction.deployment_id == request.deployment_id
         end) do
      {_token, transaction} ->
        case run_phase(:rollback, transaction, state) do
          {:ok, _response, updated_state} -> updated_state
          {:error, _reason, updated_state} -> updated_state
        end

      nil ->
        state
    end
  end

  defp fetch_transaction(state, deployment_id, token) do
    case state.transactions[token] do
      %{deployment_id: ^deployment_id} = transaction -> {:ok, transaction}
      nil -> {:error, :unknown_or_expired_token}
      _other -> {:error, :deployment_token_mismatch}
    end
  end

  defp capacity_available(state) do
    if map_size(state.transactions) < @maximum_transactions,
      do: :ok,
      else: {:error, :deployment_capacity_reached}
  end

  defp participant_idle(%{transactions: transactions}) when map_size(transactions) == 0, do: :ok
  defp participant_idle(_state), do: {:error, :deployment_in_progress}

  defp validate_request(request) when is_map(request) do
    with true <-
           Map.keys(request) |> Enum.sort() == Enum.sort(@request_keys) or
             {:error, :unexpected_deployment_fields},
         :ok <- uuid(request.deployment_id, :invalid_deployment_id),
         :ok <- uuid(request.target_id, :invalid_target_id),
         :ok <- uuid(request.build_id, :invalid_build_id),
         true <- valid_sha?(request.sha) or {:error, :invalid_source_sha},
         true <- valid_digest?(request.artifact_digest) or {:error, :invalid_artifact_digest},
         true <- valid_digest?(request.manifest_digest) or {:error, :invalid_manifest_digest},
         true <- is_binary(request.repo) or {:error, :invalid_repo},
         true <- is_binary(request.artifact_bytes) or {:error, :invalid_artifact},
         true <-
           valid_expected_nodes?(request.expected_nodes) or {:error, :invalid_expected_nodes} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_request(_request), do: {:error, :invalid_deployment_request}

  defp verify_manifest_identity(verified, request) do
    digest = BuildArtifact.digest(BuildProtocol.canonical_json(verified.manifest))

    if digest == request.manifest_digest,
      do: :ok,
      else: {:error, :manifest_digest_mismatch}
  end

  defp verify_direct_candidate(verified) do
    allowlist = Application.fetch_env!(:openagents, :forge_hot_load_allowlist)

    offenders =
      Enum.reject(verified.modules, &OpenAgents.Forge.HotLoader.allowlisted?(&1, allowlist))

    cond do
      verified.manifest["classification"] != "direct_candidate" ->
        {:error, :artifact_not_direct}

      offenders != [] ->
        {:error, :module_not_allowlisted}

      true ->
        :ok
    end
  end

  defp verify_runtime_toolchain(toolchain) do
    expected = %{
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "erts" => to_string(:erlang.system_info(:version)),
      "application_version" => to_string(Application.spec(:openagents, :vsn) || "unknown")
    }

    if Enum.all?(expected, fn {key, value} -> toolchain[key] == value end),
      do: :ok,
      else: {:error, :runtime_toolchain_mismatch}
  end

  defp candidates(beams) do
    Enum.map(beams, fn %{module: module, binary: binary} ->
      %{
        module: BuildArtifact.module_atom(module),
        name: module,
        binary: binary,
        digest: BuildArtifact.digest(binary),
        md5: beam_md5(binary)
      }
    end)
  end

  defp snapshot_prior(candidates, live) do
    Enum.reduce_while(candidates, {:ok, %{}}, fn %{module: module, name: name}, {:ok, acc} ->
      case prior_object(module, name, live) do
        {:ok, object} ->
          {:cont, {:ok, Map.put(acc, name, %{module: module, object: object})}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp prior_object(module, name, live) do
    case :code.get_object_code(module) do
      {^module, binary, file} ->
        {:ok,
         %{
           binary: binary,
           file: file,
           digest: BuildArtifact.digest(binary),
           md5: beam_md5(binary)
         }}

      :error ->
        cond do
          :code.is_loaded(module) == false ->
            {:ok, :absent}

          is_map(live) and is_map(live[:objects]) and is_map(live.objects[name]) ->
            {:ok, live.objects[name]}

          true ->
            {:error, :prior_object_code_unavailable}
        end
    end
  end

  defp prior_projection(prior) do
    prior
    |> Enum.map(fn
      {name, %{object: :absent}} ->
        %{"module" => name, "state" => "absent"}

      {name, %{object: object}} ->
        %{"module" => name, "state" => "present", "sha256" => object.digest}
    end)
    |> Enum.sort_by(& &1["module"])
  end

  defp load_candidates(candidates) do
    Enum.reduce_while(candidates, :ok, fn candidate, :ok ->
      case :code.load_binary(candidate.module, ~c"forge-transaction", candidate.binary) do
        {:module, module} when module == candidate.module -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_candidates(transaction) do
    with true <-
           Enum.all?(transaction.candidates, &candidate_loaded?/1) or
             {:error, :candidate_object_code_mismatch},
         true <-
           Enum.all?(transaction.candidates, &smoke_ok?/1) or
             {:error, :candidate_smoke_failed} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp candidate_loaded?(candidate) do
    :code.is_loaded(candidate.module) != false and
      apply(candidate.module, :module_info, [:md5]) == candidate.md5
  rescue
    _error -> false
  end

  defp smoke_ok?(candidate) do
    Code.ensure_loaded?(candidate.module) and
      (not function_exported?(candidate.module, :revision, 0) or
         is_binary(candidate.module.revision()))
  rescue
    _error -> false
  end

  defp restore_and_verify(prior) do
    with :ok <- restore_prior(prior), :ok <- verify_prior(prior), do: :ok
  end

  defp restore_prior(prior) do
    Enum.reduce_while(prior, :ok, fn
      {_name, %{module: module, object: :absent}}, :ok ->
        :code.purge(module)
        :code.delete(module)
        :code.purge(module)
        {:cont, :ok}

      {_name, %{module: module, object: object}}, :ok ->
        case :code.load_binary(module, object.file, object.binary) do
          {:module, ^module} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:restore_load_failed, reason}}}
        end
    end)
  end

  defp verify_prior(prior) do
    Enum.reduce_while(prior, :ok, fn
      {_name, %{module: module, object: :absent}}, :ok ->
        if :code.is_loaded(module) == false,
          do: {:cont, :ok},
          else: {:halt, {:error, :absent_module_remained_loaded}}

      {_name, %{module: module, object: object}}, :ok ->
        if :code.is_loaded(module) != false and
             apply(module, :module_info, [:md5]) == object.md5,
           do: {:cont, :ok},
           else: {:halt, {:error, :prior_object_code_mismatch}}
    end)
  rescue
    _error -> {:error, :prior_object_code_missing}
  end

  defp cache_artifact(bytes, digest) do
    path = Path.join([Repos.data_dir(), "beams", digest <> ".tar"])

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case BuildProtocol.atomic_write(path, bytes) do
        :ok ->
          :ok

        {:error, :destination_exists} ->
          with {:ok, existing} <- File.read(path),
               true <- BuildArtifact.digest(existing) == digest or {:error, :digest_collision} do
            :ok
          end

        {:error, reason} ->
          {:error, {:artifact_cache_write_failed, reason}}
      end
    else
      {:error, reason} -> {:error, {:artifact_cache_directory_failed, reason}}
    end
  end

  defp expire_transactions(state) do
    now = monotonic_ms()

    Enum.reduce(state.transactions, state, fn {_token, transaction}, acc ->
      if transaction.expires_at <= now do
        expire_transaction(transaction, acc)
      else
        acc
      end
    end)
  end

  defp expire_transaction(%{phase: :committed} = transaction, state) do
    case committed_authority(transaction) do
      :candidate_live ->
        phase_state(:finalize, transaction, state)

      :candidate_not_live ->
        phase_state(:rollback, transaction, state)

      :pending ->
        deferred = %{transaction | expires_at: monotonic_ms() + retry_delay_ms()}
        put_transaction(state, deferred)

      :authority_unavailable ->
        deferred = %{transaction | expires_at: monotonic_ms() + retry_delay_ms()}

        state
        |> put_transaction(deferred)
        |> Map.put(:divergence, "commit_authority_unavailable")
    end
  end

  defp expire_transaction(transaction, state), do: phase_state(:rollback, transaction, state)

  defp phase_state(phase, transaction, state) do
    case run_phase(phase, transaction, state) do
      {:ok, _response, updated_state} -> updated_state
      {:error, _reason, updated_state} -> updated_state
      {:error, _reason} -> updated_state_without(state, transaction.token)
    end
  end

  defp committed_authority(transaction) do
    Targets.deployment_authority(
      transaction.target_id,
      transaction.deployment_id,
      transaction.artifact_digest
    )
  rescue
    _error -> :authority_unavailable
  catch
    _kind, _reason -> :authority_unavailable
  end

  defp health_report(state, boot_ready? \\ nil) do
    participant =
      cond do
        state.divergence ->
          default_health(%{"ready" => false, "reason" => state.divergence})

        map_size(state.transactions) > 0 ->
          phases =
            state.transactions |> Map.values() |> Enum.map(&to_string(&1.phase)) |> Enum.uniq()

          default_health(%{
            "ready" => false,
            "reason" => "deployment_in_progress",
            "phase" => phases |> Enum.sort() |> List.first()
          })

        state.live ->
          default_health(%{
            "ready" => true,
            "reason" => "committed",
            "revision" => state.live.sha,
            "artifact_digest" => state.live.artifact_digest
          })

        true ->
          default_health()
      end

    participant = Map.put(participant, "participant_ready", participant["ready"])

    boot_ready? = if is_boolean(boot_ready?), do: boot_ready?, else: BootConverge.ready?()

    if participant["ready"] and not boot_ready? do
      %{participant | "ready" => false, "reason" => "boot_not_converged"}
    else
      participant
    end
  end

  defp default_health(overrides \\ %{}) do
    Map.merge(
      %{
        "schema" => "openagents.forge.deployment-node.v1",
        "ready" => true,
        "participant_ready" => true,
        "reason" => "idle",
        "phase" => "idle",
        "revision" => OpenAgents.BuildInfo.revision(),
        "artifact_digest" => nil
      },
      overrides
    )
  end

  defp unavailable_health do
    default_health(%{
      "ready" => false,
      "participant_ready" => false,
      "reason" => "participant_unavailable"
    })
  end

  defp live_identity(transaction) do
    %{
      repo: transaction.repo,
      sha: transaction.sha,
      target_id: transaction.target_id,
      build_id: transaction.manifest["build_id"],
      artifact_digest: transaction.artifact_digest,
      manifest_digest: transaction.manifest_digest,
      modules: length(transaction.candidates),
      objects:
        Map.new(transaction.candidates, fn candidate ->
          {candidate.name,
           %{
             binary: candidate.binary,
             file: ~c"forge-transaction",
             digest: candidate.digest,
             md5: candidate.md5
           }}
        end)
    }
  end

  defp beam_md5(binary) do
    {:ok, {_module, md5}} = :beam_lib.md5(binary)
    md5
  end

  defp put_transaction(state, transaction),
    do: put_in(state, [:transactions, transaction.token], transaction)

  defp updated_state_without(state, token),
    do: %{state | transactions: Map.delete(state.transactions, token)}

  defp run_fault(stage, state) do
    case Map.get(state.faults, stage) do
      nil ->
        :ok

      :error ->
        {:error, :injected_failure}

      :timeout ->
        receive do
          :release_injected_timeout -> :ok
        after
          state.fault_timeout_ms -> {:error, :injected_timeout}
        end

      other ->
        {:error, {:invalid_injected_fault, other}}
    end
  end

  defp notify(%{notify: pid}, stage) when is_pid(pid),
    do: send(pid, {:forge_deployment_node, node(), stage})

  defp notify(_state, _stage), do: :ok

  defp uuid(value, reason) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, reason}
    end
  end

  defp valid_sha?(value), do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{40}$/, value)

  defp valid_digest?(value),
    do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{64}$/, value)

  defp valid_expected_nodes?(nodes) when is_list(nodes) and length(nodes) in 1..100 do
    nodes == Enum.sort(Enum.uniq(nodes)) and
      Enum.all?(nodes, &(is_binary(&1) and byte_size(&1) in 1..255))
  end

  defp valid_expected_nodes?(_nodes), do: false

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp timeout_ms,
    do: Application.get_env(:openagents, :forge_deploy_timeout_ms, @default_timeout_ms)

  defp token_ttl_ms,
    do: Application.get_env(:openagents, :forge_deploy_token_ttl_ms, @default_token_ttl_ms)

  defp retry_delay_ms,
    do: Application.get_env(:openagents, :forge_boot_retry_min_ms, 1_000)

  defp persist(state) do
    :persistent_term.put(@state_key, %{
      schema: 1,
      transactions: state.transactions,
      live: state.live,
      divergence: state.divergence
    })

    state
  end
end
