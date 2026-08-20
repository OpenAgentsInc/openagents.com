defmodule OpenAgents.Forge.BootConverge do
  @moduledoc """
  Boot convergence (roadmap P6, issue #123): on node start — after the Repo,
  before Horde/Ra membership or the endpoint — load the current live fleet
  target's beam artifact, so **a node converges to the forge's target
  commit, not to the image**. Image rebakes become structural-only.

  Honesty rules:
  - If there is no live target, no local artifact (a freshly replaced node
    has an empty partition — artifacts are per-node cache), an off-allowlist
    module, or any error, the node boots on image code and records why —
    it NEVER refuses to start. The state is published in `state/0` and on
    the public status page's per-node report.
  - The same operator-owned allowlist as the hot-load lane gates what boot
    convergence will load: convergence is a replay of an approved deploy,
    not a second authority (SELF-EDIT-001: hot-loaded code is a projection
    of the promoted commit).

  Runs synchronously inside `start_link/1` and returns `:ignore` — it is a
  boot step, not a process.
  """

  require Logger

  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.BuildProtocol
  alias OpenAgents.Forge.HotLoader
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.Targets

  @state_key {__MODULE__, :state}

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker, restart: :temporary}
  end

  def start_link do
    if Application.get_env(:openagents, :forge_boot_converge_enabled, false) do
      converge()
    end

    :ignore
  end

  @doc "The boot-convergence outcome for this node (for /status honesty)."
  def state do
    :persistent_term.get(@state_key, %{"state" => "image", "reason" => "not_attempted"})
  end

  @doc false
  def converge(repo \\ "openagents.com") do
    outcome =
      try do
        attempt(repo)
      rescue
        error ->
          %{"state" => "image", "reason" => OpenAgents.OperationalLog.code(error)}
      catch
        _kind, reason ->
          %{"state" => "image", "reason" => OpenAgents.OperationalLog.code(reason)}
      end

    :persistent_term.put(@state_key, outcome)

    case outcome do
      %{"state" => "converged", "sha" => sha} ->
        Logger.info("forge boot convergence: loaded target #{sha}")

      %{"reason" => reason} ->
        Logger.info("forge boot convergence: booting on image code (#{reason})")
    end

    outcome
  end

  defp attempt(repo) do
    case Targets.current(repo) do
      %{
        status: "live",
        sha: sha,
        details: %{
          "artifact" => relative,
          "artifact_digest" => digest,
          "build_id" => build_id
        }
      }
      when is_binary(relative) and is_binary(digest) and is_binary(build_id) ->
        load_artifact(repo, sha, digest, build_id, Path.join(Repos.data_dir(), relative))

      %{status: "live", details: %{"artifact" => _relative}} ->
        %{"state" => "image", "reason" => "artifact_identity_missing"}

      %{status: "live", sha: sha} ->
        # A live target with no artifact recorded (a no-op deploy): the
        # image already is that code as far as this lane knows.
        %{"state" => "converged", "sha" => sha, "modules" => 0}

      %{status: status} ->
        %{"state" => "image", "reason" => "target_not_live:#{status}"}

      nil ->
        %{"state" => "image", "reason" => "no_target"}
    end
  end

  defp load_artifact(repo, sha, digest, build_id, artifact) do
    cond do
      not File.exists?(artifact) ->
        # The local cache misses on a replaced node — fetch the blob the
        # builder uploaded next to the WAL, then converge from it. Only if
        # the store misses too does the node boot on image code.
        case OpenAgents.Forge.WAL.get_artifact(repo, digest) do
          {:ok, payload} ->
            with {:ok, verified} <-
                   BuildArtifact.verify(payload,
                     digest: digest,
                     repo: repo,
                     source_sha: sha,
                     build_id: build_id
                   ) do
              # Cache only bytes that passed the immutable identity check.
              _cache_result = BuildProtocol.atomic_write(artifact, payload)
              load_beams_from(sha, verified)
            else
              {:error, _reason} ->
                %{"state" => "image", "reason" => "artifact_verification_failed"}
            end

          {:error, _reason} ->
            %{"state" => "image", "reason" => "artifact_missing"}
        end

      true ->
        case BuildArtifact.verify_file(artifact,
               digest: digest,
               repo: repo,
               source_sha: sha,
               build_id: build_id
             ) do
          {:ok, verified} ->
            load_beams_from(sha, verified)

          {:error, _reason} ->
            %{"state" => "image", "reason" => "artifact_verification_failed"}
        end
    end
  end

  defp load_beams_from(sha, verified) do
    allowlist = Application.get_env(:openagents, :forge_hot_load_allowlist, default_allowlist())

    offenders =
      verified.modules
      |> Enum.reject(&HotLoader.allowlisted?(&1, allowlist))

    cond do
      verified.manifest["classification"] != "direct_candidate" ->
        %{"state" => "image", "reason" => "artifact_not_direct"}

      offenders != [] ->
        %{"state" => "image", "reason" => "off_allowlist:#{Enum.join(offenders, ",")}"}

      true ->
        # Atom creation follows complete verification and policy checks.
        beams =
          Enum.map(verified.beams, fn %{module: module, binary: binary} ->
            {BuildArtifact.module_atom(module), binary}
          end)

        failures =
          beams
          |> HotLoader.load_beams()
          |> Enum.reject(fn {_mod, result} -> result == :ok end)

        if failures == [] do
          %{"state" => "converged", "sha" => sha, "modules" => length(beams)}
        else
          %{"state" => "image", "reason" => "load_failed"}
        end
    end
  end

  defp default_allowlist, do: ["OpenAgents.Scratch.", "OpenAgents.BuildInfo"]
end
