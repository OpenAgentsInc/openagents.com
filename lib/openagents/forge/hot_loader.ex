defmodule OpenAgents.Forge.HotLoader do
  @moduledoc """
  Coordinates immutable build artifacts through the transactional direct-load
  lane. The coordinator refuses structural or off-allowlist changes before
  deployment, then delegates prepare, canary, fleet apply, verification,
  commit, and exact rollback to `OpenAgents.Forge.Deployment`.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.Deployment
  alias OpenAgents.Forge.DeploymentLane
  alias OpenAgents.Forge.DeployReceipt
  alias OpenAgents.Forge.{Pushes, PushReceipt}
  alias OpenAgents.Forge.Targets
  alias OpenAgents.Repo

  @builds_topic "forge:builds"
  @deploys_topic "forge:deploys"
  @default_allowlist ["OpenAgents.Scratch.", "OpenAgents.BuildInfo"]

  # ── api ──────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Whether `module_name` may be hot-loaded under `allowlist`. An entry ending
  in `.` is a prefix (`"OpenAgents.Scratch."`); any other entry is an exact
  module name. The `Elixir.` prefix is ignored.
  """
  def allowlisted?(module_name, allowlist) do
    name = String.replace_prefix(module_name, "Elixir.", "")

    Enum.any?(allowlist, fn entry ->
      entry == name or (String.ends_with?(entry, ".") and String.starts_with?(name, entry))
    end)
  end

  # ── genserver ────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Subscribe from handle_continue with retry: the deploy lane degrades
    # honestly if PubSub is not up yet — it never takes the application down
    # (2026-08-19 fleet boot-order incident).
    {:ok, %{}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    try do
      Phoenix.PubSub.subscribe(OpenAgents.PubSub, @builds_topic)
    rescue
      _error -> Process.send_after(self(), :resubscribe, 1_000)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:resubscribe, state), do: handle_continue(:subscribe, state)

  def handle_info({:forge_build_ready, build}, state) do
    handle_build(build)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── deploy lane ──────────────────────────────────────────────────────────

  defp handle_build(%{repo: repo, sha: sha, target_id: target_id, modules: modules} = build) do
    if File.exists?(build.artifact) do
      with {:ok, artifact_bytes} <- File.read(build.artifact),
           {:ok, verified} <-
             BuildArtifact.verify(artifact_bytes,
               digest: Map.get(build, :artifact_digest),
               repo: repo,
               source_sha: sha,
               build_id: Map.get(build, :build_id)
             ),
           true <- verified.modules == modules or {:error, :declared_modules_mismatch},
           true <-
             is_nil(Map.get(build, :manifest)) or Map.get(build, :manifest) == verified.manifest or
               {:error, :declared_manifest_mismatch} do
        route_verified(build, verified, artifact_bytes)
      else
        {:error, reason} -> fail_verified_build(build, reason)
      end
    end
  rescue
    error ->
      message = "hot_load_failed code=" <> OpenAgents.OperationalLog.code(error)
      Logger.error("forge_hot_load_failed code=#{OpenAgents.OperationalLog.code(error)}")
      advance(target_id, "failed", %{"error" => message})
      insert_receipt(repo, sha, target_id, modules, [], "failed", "direct_load", nil, nil)
      broadcast_deploy(repo, sha, "failed")
  catch
    :refused -> :ok
  end

  # The lane is chosen once, in front, from the candidate's manifest and the
  # fleet's own relup topology verdict, before any node is touched. The relup
  # lane is not admitted here: RELEASE-005 keeps its workers disabled until
  # isolated staging proves their provider and topology, so this coordinator
  # sees only the direct and rolling lanes. RELEASE-008's preinstall refusal
  # remains the backstop underneath.
  defp route_verified(build, verified, artifact_bytes) do
    allowlist = Application.get_env(:openagents, :forge_hot_load_allowlist, @default_allowlist)
    offending = Enum.reject(verified.modules, &allowlisted?(&1, allowlist))

    lane =
      DeploymentLane.classify(verified.manifest,
        offending: offending,
        topology: DeploymentLane.fleet_topology()
      )

    case lane do
      %{"lane" => "direct"} ->
        build =
          build
          |> Map.put(:artifact_digest, verified.digest)
          |> Map.put(:build_id, verified.manifest["build_id"])
          |> Map.put(:manifest, verified.manifest)

        deploy(build, verified, artifact_bytes)

      %{"reasons" => reasons, "topology" => topology} ->
        route_rolling(build, reasons, topology)
    end
  end

  defp route_rolling(
         %{repo: repo, sha: sha, target_id: target_id, modules: modules},
         reasons,
         topology
       ) do
    case advance(target_id, "needs_rolling_replace", %{
           "modules" => modules,
           "reasons" => reasons,
           "topology" => topology
         }) do
      :ok ->
        # Classification only — no deployment ran, so no deployment_type.
        insert_receipt(repo, sha, target_id, modules, [], "needs_rolling_replace", nil, nil, nil)
        broadcast_deploy(repo, sha, "needs_rolling_replace")

      :error ->
        :ok
    end
  end

  defp fail_verified_build(
         %{repo: repo, sha: sha, target_id: target_id, modules: modules},
         reason
       ) do
    message = "artifact_verification_failed code=" <> OpenAgents.OperationalLog.code(reason)
    Logger.error(message)
    advance(target_id, "failed", %{"error" => message})
    insert_receipt(repo, sha, target_id, modules, [], "failed", "direct_load", nil, nil)
    broadcast_deploy(repo, sha, "failed")
  end

  defp deploy(%{target_id: target_id} = build, verified, bytes) do
    case Targets.begin_deployment(target_id) do
      {:ok, _target} ->
        run_transaction(build, verified, bytes)

      {:error, reason} ->
        Logger.warning("forge_deployment_refused code=#{OpenAgents.OperationalLog.code(reason)}")
    end
  rescue
    error ->
      fail_started_deployment(build, %{error_code: OpenAgents.OperationalLog.code(error)})
  catch
    kind, reason ->
      fail_started_deployment(build, %{error_code: OpenAgents.OperationalLog.code({kind, reason})})
  end

  defp run_transaction(build, verified, bytes) do
    case Deployment.run(build, verified, bytes) do
      {:ok, session} -> commit_live(build, session)
      {:error, outcome} -> finish_failed_transaction(build, outcome)
    end
  end

  defp commit_live(build, session) do
    receipt = receipt_attributes(build, session, "ok", push_to_live_ms(build.repo, build.sha))

    case Targets.finish_deployment(
           build.target_id,
           "live",
           live_details(build, session),
           receipt
         ) do
      {:ok, _committed} ->
        case Deployment.finalize(session) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "forge_deployment_finalize_failed code=#{OpenAgents.OperationalLog.code(reason)}"
            )
        end

        broadcast_deploy(build.repo, build.sha, "live")

      {:error, reason} ->
        rollback_after_database_failure(build, session, reason)
    end
  end

  defp rollback_after_database_failure(build, session, database_reason) do
    case Deployment.rollback(session) do
      {:ok, node_results} ->
        outcome =
          session
          |> Map.merge(%{
            result: "reverted",
            rollback_verified: true,
            error_code: OpenAgents.OperationalLog.code(database_reason),
            node_results: node_results,
            nodes: node_lines(node_results)
          })

        finish_failed_transaction(build, outcome)

      {:error, node_results} ->
        outcome =
          session
          |> Map.merge(%{
            result: "failed",
            rollback_verified: false,
            error_code: "database_commit_and_rollback_failed",
            node_results: node_results,
            nodes: node_lines(node_results)
          })

        finish_failed_transaction(build, outcome)
    end
  end

  defp finish_failed_transaction(build, outcome) do
    status = if outcome.result == "reverted", do: "reverted", else: "failed"
    details = %{"error_code" => outcome.error_code, "modules" => build.modules}
    receipt = receipt_attributes(build, outcome, bounded(outcome.error_code), nil)

    case Targets.finish_deployment(build.target_id, status, details, receipt) do
      {:ok, _committed} ->
        broadcast_deploy(build.repo, build.sha, status)

      {:error, reason} ->
        Logger.error(
          "forge_deployment_receipt_failed code=#{OpenAgents.OperationalLog.code(reason)}"
        )
    end
  end

  defp fail_started_deployment(build, outcome) do
    defaults = %{
      deployment_id: Ecto.UUID.generate(),
      artifact_digest: Map.get(build, :artifact_digest),
      manifest_digest: manifest_digest(Map.get(build, :manifest)),
      expected_nodes: [],
      node_results: %{},
      nodes: [],
      canary: nil,
      rollback_verified: false,
      started_at: DateTime.utc_now(),
      result: "failed"
    }

    finish_failed_transaction(build, Map.merge(defaults, outcome))
  end

  # Every terminal outcome is announced on the deploys topic — live,
  # reverted, needs_rolling_replace, and failed alike.
  defp broadcast_deploy(repo, sha, result) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      @deploys_topic,
      {:forge_deploy, %{repo: repo, sha: sha, result: result}}
    )
  end

  @doc "Verify an artifact completely, then return `{module_atom, binary}` pairs."
  def extract!(artifact) do
    case BuildArtifact.verify_file(artifact) do
      {:ok, verified} ->
        Enum.map(verified.beams, fn %{module: module, binary: binary} ->
          {BuildArtifact.module_atom(module), binary}
        end)

      {:error, reason} ->
        raise "artifact verification failed for #{artifact}: #{inspect(reason)}"
    end
  end

  # ── receipts ─────────────────────────────────────────────────────────────

  # Push→live duration: the push receipt whose refs advanced some ref to
  # this sha marks when the loop started.
  defp push_to_live_ms(repo, sha) do
    repo_keys = Pushes.receipt_repo_keys(repo)

    PushReceipt
    |> where([p], p.repo in ^repo_keys)
    |> order_by([p], desc: p.inserted_at)
    |> limit(100)
    |> Repo.all()
    |> Enum.find(fn receipt ->
      Enum.any?(receipt.refs || %{}, fn
        {_ref, %{"new" => new}} -> new == sha
        {_ref, _} -> false
      end)
    end)
    |> case do
      nil -> nil
      %PushReceipt{inserted_at: at} -> DateTime.diff(DateTime.utc_now(), at, :millisecond)
    end
  end

  defp insert_receipt(
         repo,
         sha,
         target_id,
         modules,
         nodes,
         result,
         deployment_type,
         canary,
         push_ms
       ) do
    %DeployReceipt{}
    |> DeployReceipt.changeset(%{
      repo: repo,
      sha: sha,
      target_id: target_id,
      modules: modules,
      nodes: nodes,
      result: result,
      deployment_type: deployment_type,
      canary: canary,
      push_to_live_ms: push_ms
    })
    |> Repo.insert()
  rescue
    error ->
      Logger.error("forge_deploy_receipt_failed code=#{OpenAgents.OperationalLog.code(error)}")
      :error
  end

  defp receipt_attributes(build, outcome, canary, push_ms) do
    %{
      deployment_id: outcome.deployment_id,
      artifact_digest: outcome.artifact_digest,
      manifest_digest: outcome.manifest_digest,
      modules: build.modules,
      nodes: outcome.nodes,
      expected_nodes: outcome.expected_nodes,
      node_results: outcome.node_results,
      deployment_type: "direct_load",
      canary: canary || outcome.canary,
      error_code: outcome.error_code,
      rollback_verified: outcome.rollback_verified,
      started_at: outcome.started_at,
      push_to_live_ms: push_ms
    }
  end

  defp live_details(build, session) do
    %{
      "artifact" => Map.get(build, :artifact) |> relative_artifact(),
      "artifact_digest" => session.artifact_digest,
      "build_id" => build.build_id,
      "deployment_id" => session.deployment_id,
      "manifest" => build.manifest,
      "manifest_digest" => session.manifest_digest,
      "modules" => build.modules,
      "nodes" => length(session.expected_nodes)
    }
  end

  defp relative_artifact(nil), do: nil

  defp relative_artifact(path) do
    Path.relative_to(path, OpenAgents.Forge.Repos.data_dir())
  end

  defp manifest_digest(nil), do: nil

  defp manifest_digest(manifest) do
    manifest
    |> OpenAgents.Forge.BuildProtocol.canonical_json()
    |> BuildArtifact.digest()
  end

  defp node_lines(results),
    do: results |> Enum.map(fn {node, result} -> "#{node}=#{result}" end) |> Enum.sort()

  defp advance(target_id, status, details) do
    case Targets.advance(target_id, status, details) do
      {:ok, _target} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "forge_hot_load_advance_refused target=#{target_id} status=#{status} " <>
            "code=#{OpenAgents.OperationalLog.code(reason)}"
        )

        :error
    end
  rescue
    error ->
      Logger.error("forge_hot_load_advance_failed code=#{OpenAgents.OperationalLog.code(error)}")
      :error
  end

  defp bounded(text) when is_binary(text),
    do: text |> OpenAgents.LogSafety.redact() |> String.slice(0, 500)

  defp bounded(other), do: OpenAgents.OperationalLog.code(other)
end
