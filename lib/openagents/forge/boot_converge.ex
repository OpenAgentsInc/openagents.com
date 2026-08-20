defmodule OpenAgents.Forge.BootConverge do
  @moduledoc """
  Gates readiness on convergence to the newest immutable live target.

  A cold node fetches the live artifact from durable storage when its local
  digest-addressed cache is empty, verifies the same artifact and manifest
  identities used during promotion, and installs it through the transactional
  node participant. A divergent node stays out of readiness and retries with
  bounded exponential backoff. The public state contains only identity hashes,
  counters, and stable reason codes.
  """

  use GenServer

  require Logger

  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.BuildProtocol
  alias OpenAgents.Forge.DeploymentNode
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.Targets

  @state_key {__MODULE__, :state}
  @default_retry_min_ms 1_000
  @default_retry_max_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Return this node's bounded convergence state."
  def state do
    :persistent_term.get(@state_key, initial_state(false))
  end

  @doc "Return whether this node may enter external readiness."
  def ready?(repo \\ "openagents.com") do
    convergence = state()

    cond do
      convergence["ready"] != true -> false
      not Application.get_env(:openagents, :forge_boot_converge_enabled, false) -> true
      true -> durable_target_ready?(repo, convergence)
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  @doc false
  def ready_for_deployment?(repo, target_id) do
    convergence = state()

    cond do
      convergence["ready"] != true -> false
      not Application.get_env(:openagents, :forge_boot_converge_enabled, false) -> true
      true -> deployment_target_ready?(repo, target_id, convergence)
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  @doc "Run one synchronous convergence attempt. Tests and repair tools use this API."
  def converge(repo \\ "openagents.com") do
    outcome = safe_attempt(repo, state()["attempts"] + 1)
    publish(outcome)
    outcome
  end

  @doc false
  def mark_converged(identity) when is_map(identity) do
    outcome = %{
      "schema" => "openagents.forge.boot-convergence.v2",
      "state" => "converged",
      "ready" => true,
      "reason" => "fleet_commit",
      "sha" => identity.sha,
      "artifact_digest" => identity.artifact_digest,
      "manifest_digest" => identity.manifest_digest,
      "modules" => identity.modules,
      "attempts" => state()["attempts"],
      "retry_in_ms" => nil
    }

    publish(outcome)
  end

  @doc false
  def restore_state(%{"schema" => "openagents.forge.boot-convergence.v2"} = outcome),
    do: publish(outcome)

  @impl true
  def init(opts) do
    repo = Keyword.get(opts, :repo, "openagents.com")
    enabled? = Application.get_env(:openagents, :forge_boot_converge_enabled, false)

    if enabled? do
      outcome = safe_attempt(repo, 1)

      if outcome["ready"] do
        publish(outcome)
        Process.send_after(self(), :retry_convergence, retry_max_ms())
        {:ok, %{repo: repo, retry_ms: retry_min_ms()}}
      else
        retry_ms = retry_min_ms()
        publish(Map.put(outcome, "retry_in_ms", retry_ms))
        Process.send_after(self(), :retry_convergence, retry_ms)
        {:ok, %{repo: repo, retry_ms: min(retry_ms * 2, retry_max_ms())}}
      end
    else
      publish(initial_state(false))
      {:ok, %{repo: repo, retry_ms: retry_min_ms()}}
    end
  end

  @impl true
  def handle_info(:retry_convergence, server_state), do: run_convergence(server_state)
  def handle_info(_message, server_state), do: {:noreply, server_state}

  defp run_convergence(server_state) do
    outcome = safe_attempt(server_state.repo, state()["attempts"] + 1)

    if outcome["ready"] do
      publish(outcome)
      Process.send_after(self(), :retry_convergence, retry_max_ms())
      {:noreply, %{server_state | retry_ms: retry_min_ms()}}
    else
      retry_ms = min(server_state.retry_ms, retry_max_ms())
      outcome = Map.put(outcome, "retry_in_ms", retry_ms)
      publish(outcome)
      Process.send_after(self(), :retry_convergence, retry_ms)
      {:noreply, %{server_state | retry_ms: min(retry_ms * 2, retry_max_ms())}}
    end
  end

  defp safe_attempt(repo, attempts) do
    attempt(repo, attempts)
  rescue
    error -> degraded("convergence_exception", attempts, error)
  catch
    _kind, reason -> degraded("convergence_exit", attempts, reason)
  end

  defp durable_target_ready?(repo, convergence) do
    case Targets.current(repo) do
      %{status: "deploying"} -> false
      _not_deploying -> current_target_matches?(repo, convergence)
    end
  end

  defp deployment_target_ready?(repo, target_id, convergence) do
    case Targets.current(repo) do
      %{id: ^target_id, status: "deploying"} -> current_target_matches?(repo, convergence)
      _other_target -> false
    end
  end

  defp current_target_matches?(repo, convergence) do
    case {Targets.live(repo), convergence} do
      {nil, %{"state" => "image", "reason" => "no_live_target"}} ->
        true

      {%{sha: sha, details: details}, %{"sha" => sha, "artifact_digest" => nil}} ->
        (details || %{})["artifact_digest"] == nil and OpenAgents.BuildInfo.revision() == sha

      {%{sha: sha, details: details},
       %{
         "sha" => sha,
         "artifact_digest" => artifact_digest,
         "manifest_digest" => manifest_digest
       }} ->
        details = details || %{}

        details["artifact_digest"] == artifact_digest and
          details["manifest_digest"] == manifest_digest

      _divergent ->
        false
    end
  end

  defp attempt(repo, attempts) do
    case Targets.live(repo) do
      nil ->
        image_ready("no_live_target", attempts)

      %{sha: sha, details: details} = target ->
        converge_target(repo, target, sha, details || %{}, attempts)
    end
  end

  defp converge_target(repo, target, sha, details, attempts) do
    with {:ok, identity} <- target_identity(target, details),
         {:ok, bytes, cache_state} <- artifact_bytes(repo, identity),
         {:ok, response} <- DeploymentNode.install_artifact(install_request(identity, bytes)),
         :ok <- retain_artifacts(repo, target.id, identity.artifact_digest) do
      %{
        "schema" => "openagents.forge.boot-convergence.v2",
        "state" => "converged",
        "ready" => true,
        "reason" => cache_state,
        "sha" => sha,
        "artifact_digest" => identity.artifact_digest,
        "manifest_digest" => identity.manifest_digest,
        "modules" => response["modules"] || identity.modules,
        "attempts" => attempts,
        "retry_in_ms" => nil
      }
    else
      {:image_matches, ^sha} ->
        image_ready("image_matches_live", attempts, sha)

      {:error, reason} ->
        degraded(OpenAgents.OperationalLog.code(reason), attempts, reason, sha)
    end
  end

  defp target_identity(target, details) do
    case details do
      %{
        "artifact_digest" => artifact_digest,
        "build_id" => build_id,
        "manifest" => manifest
      }
      when is_binary(artifact_digest) and is_binary(build_id) and is_map(manifest) ->
        manifest_digest =
          details["manifest_digest"] ||
            BuildArtifact.digest(BuildProtocol.canonical_json(manifest))

        changes = manifest["changes"] || %{}
        modules = (changes["added"] || []) ++ (changes["changed"] || [])

        {:ok,
         %{
           repo: target.repo,
           sha: target.sha,
           target_id: target.id,
           build_id: build_id,
           artifact_digest: artifact_digest,
           manifest_digest: manifest_digest,
           modules: length(modules)
         }}

      _missing ->
        if OpenAgents.BuildInfo.revision() == target.sha,
          do: {:image_matches, target.sha},
          else: {:error, :live_artifact_identity_missing}
    end
  end

  defp artifact_bytes(repo, identity) do
    path = cache_path(identity.artifact_digest)

    case File.read(path) do
      {:ok, bytes} ->
        with {:ok, _verified} <- verify_artifact(bytes, identity) do
          {:ok, bytes, "local_cache"}
        end

      {:error, :enoent} ->
        with {:ok, bytes} <- OpenAgents.Forge.WAL.get_artifact(repo, identity.artifact_digest),
             {:ok, _verified} <- verify_artifact(bytes, identity),
             :ok <- cache_verified(path, bytes, identity.artifact_digest) do
          {:ok, bytes, "durable_fetch"}
        end

      {:error, reason} ->
        {:error, {:artifact_cache_read_failed, reason}}
    end
  end

  defp verify_artifact(bytes, identity) do
    BuildArtifact.verify(bytes,
      digest: identity.artifact_digest,
      repo: identity.repo,
      source_sha: identity.sha,
      build_id: identity.build_id
    )
  end

  defp install_request(identity, bytes) do
    %{
      artifact_bytes: bytes,
      artifact_digest: identity.artifact_digest,
      build_id: identity.build_id,
      deployment_id: Ecto.UUID.generate(),
      expected_nodes: [to_string(Node.self())],
      manifest_digest: identity.manifest_digest,
      repo: identity.repo,
      sha: identity.sha,
      target_id: identity.target_id
    }
  end

  defp retain_artifacts(repo, current_target_id, current_digest) do
    with {:ok, predecessor_digest} <- retain_predecessor(repo, current_target_id) do
      [current_digest, predecessor_digest]
      |> Enum.reject(&is_nil/1)
      |> prune_artifact_cache()
    end
  end

  defp retain_predecessor(repo, current_target_id) do
    predecessor =
      repo
      |> Targets.live_history(3)
      |> Enum.reject(&(&1.id == current_target_id))
      |> List.first()

    case predecessor do
      nil -> {:ok, nil}
      target -> ensure_target_cached(repo, target)
    end
  end

  defp ensure_target_cached(repo, target) do
    details = target.details || %{}

    with {:ok, identity} <- target_identity(target, details),
         {:ok, _bytes, _source} <- artifact_bytes(repo, identity) do
      {:ok, identity.artifact_digest}
    else
      {:image_matches, _sha} -> {:ok, nil}
      {:error, reason} -> {:error, {:rollback_artifact_unavailable, reason}}
    end
  end

  defp prune_artifact_cache(retained_digests) do
    directory = Path.join(Repos.data_dir(), "beams")
    retained = MapSet.new(retained_digests)

    case File.ls(directory) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          case Regex.run(~r/^([0-9a-f]{64})\.tar$/, entry) do
            [_, digest] ->
              if MapSet.member?(retained, digest) do
                {:cont, :ok}
              else
                case File.rm(Path.join(directory, entry)) do
                  :ok -> {:cont, :ok}
                  {:error, :enoent} -> {:cont, :ok}
                  {:error, reason} -> {:halt, {:error, {:artifact_prune_failed, reason}}}
                end
              end

            nil ->
              {:cont, :ok}
          end
        end)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:artifact_cache_list_failed, reason}}
    end
  end

  defp cache_verified(path, bytes, digest) do
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

  defp cache_path(digest), do: Path.join([Repos.data_dir(), "beams", digest <> ".tar"])

  defp image_ready(reason, attempts, sha \\ nil) do
    %{
      "schema" => "openagents.forge.boot-convergence.v2",
      "state" => "image",
      "ready" => true,
      "reason" => reason,
      "sha" => sha || OpenAgents.BuildInfo.revision(),
      "artifact_digest" => nil,
      "manifest_digest" => nil,
      "modules" => 0,
      "attempts" => attempts,
      "retry_in_ms" => nil
    }
  end

  defp degraded(code, attempts, _reason, sha \\ nil) do
    Logger.warning("forge_boot_convergence_degraded code=#{code}")

    %{
      "schema" => "openagents.forge.boot-convergence.v2",
      "state" => "degraded",
      "ready" => false,
      "reason" => String.slice(code, 0, 128),
      "sha" => sha,
      "artifact_digest" => nil,
      "manifest_digest" => nil,
      "modules" => 0,
      "attempts" => attempts,
      "retry_in_ms" => nil
    }
  end

  defp initial_state(false) do
    %{
      "schema" => "openagents.forge.boot-convergence.v2",
      "state" => "disabled",
      "ready" => true,
      "reason" => "feature_disabled",
      "sha" => OpenAgents.BuildInfo.revision(),
      "artifact_digest" => nil,
      "manifest_digest" => nil,
      "modules" => 0,
      "attempts" => 0,
      "retry_in_ms" => nil
    }
  end

  defp publish(outcome) do
    :persistent_term.put(@state_key, outcome)
    outcome
  end

  defp retry_min_ms do
    Application.get_env(:openagents, :forge_boot_retry_min_ms, @default_retry_min_ms)
  end

  defp retry_max_ms do
    Application.get_env(:openagents, :forge_boot_retry_max_ms, @default_retry_max_ms)
  end
end
