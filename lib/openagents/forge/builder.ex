defmodule OpenAgents.Forge.Builder do
  @moduledoc """
  Serial build worker for the forge deploy lane. Subscribes to
  `forge:target` promotions; on each one it advances the target to
  `building`, runs the configured `OpenAgents.Forge.BuildExecutor`, writes the
  changed-beam artifact tar under `<data_dir>/beams/<sha>.tar`, records a
  `OpenAgents.Forge.BuildReceipt`, advances the target to `built` (or
  `failed` with bounded output), and broadcasts build-ready on
  `forge:builds` for the hot-load lane (P4).

  One build at a time by construction: the work happens inline in
  `handle_info/2`. A bad build never crashes the worker — failures land
  on the target as status `failed` with a bounded message.
  """

  use GenServer

  require Logger

  alias OpenAgents.Forge.BuildExecutor
  alias OpenAgents.Forge.BuildReceipt
  alias OpenAgents.Forge.Repos
  alias OpenAgents.Forge.Targets
  alias OpenAgents.Repo

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

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
      Phoenix.PubSub.subscribe(OpenAgents.PubSub, "forge:target")
    rescue
      _error -> Process.send_after(self(), :resubscribe, 1_000)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:resubscribe, state), do: handle_continue(:subscribe, state)

  def handle_info({:forge_target, %{repo: repo, sha: sha, target_id: target_id}}, state) do
    run_build(repo, sha, target_id)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── one build, start to finish, crash-safe ──────────────────────────────

  defp run_build(repo, sha, target_id) do
    # Every node's Builder hears the promotion; only the one that wins the
    # promoted->building transition builds. The rest skip silently. Nodes
    # with a cold build workspace hold back briefly so a warm node wins the
    # transition when one exists (preference for efficiency; correctness
    # never depends on which node builds — the Continuity shape).
    unless warm_workspace?(), do: Process.sleep(5_000)

    case Targets.advance(target_id, "building") do
      {:ok, _target} ->
        case executor().build(repo, sha, []) do
          {:ok, result} -> finish(repo, sha, target_id, result)
          {:error, output} -> fail(target_id, output)
        end

      {:error, reason} ->
        Logger.debug("forge build: not this node's build (#{inspect(reason)})")
        :ok
    end
  rescue
    error ->
      fail(target_id, "builder crashed: " <> Exception.message(error))
  end

  defp finish(repo, sha, target_id, result) do
    modules = Enum.map(result.beams, & &1.module)
    {artifact_abs, artifact_rel} = write_artifact!(sha, result.beams)
    upload_artifact(repo, sha, artifact_abs)
    record_receipt(repo, sha, target_id, modules, artifact_rel, result)

    case Targets.advance(target_id, "built", %{"artifact" => artifact_rel, "modules" => modules}) do
      {:ok, _target} ->
        Phoenix.PubSub.broadcast(
          OpenAgents.PubSub,
          "forge:builds",
          {:forge_build_ready,
           %{repo: repo, sha: sha, target_id: target_id, artifact: artifact_abs, modules: modules}}
        )

      {:error, reason} ->
        Logger.warning("forge build: advance to built failed: #{inspect(reason)}")
    end
  end

  defp fail(target_id, output) do
    case Targets.advance(target_id, "failed", %{"error" => BuildExecutor.bound_output(output)}) do
      {:ok, _target} ->
        :ok

      {:error, reason} ->
        Logger.warning("forge build: advance to failed failed: #{inspect(reason)}")
    end
  end

  # ── artifact + receipt ──────────────────────────────────────────────────

  defp write_artifact!(sha, beams) do
    artifact_rel = Path.join("beams", sha <> ".tar")
    artifact_abs = Path.join(Repos.data_dir(), artifact_rel)

    # The sidecar executor already wrote this artifact (as root, in prod);
    # rewriting it from the unprivileged app both fails on permissions and
    # is redundant — the existing tar IS the artifact of record. Only
    # non-sidecar executors (tests, future in-process builds) write here.
    unless File.exists?(artifact_abs) do
      File.mkdir_p!(Path.dirname(artifact_abs))

      entries =
        Enum.map(beams, fn %{module: module, binary: binary} ->
          {String.to_charlist(module <> ".beam"), binary}
        end)

      :ok = :erl_tar.create(String.to_charlist(artifact_abs), entries)
    end

    {artifact_abs, artifact_rel}
  end

  # Best-effort artifact upload to the WAL store (P6, #123): a replaced
  # node with an empty partition boot-converges by fetching this blob. The
  # local tar remains the deploy path; the upload never blocks a build.
  defp upload_artifact(repo, sha, artifact_abs) do
    case File.read(artifact_abs) do
      {:ok, payload} ->
        case OpenAgents.Forge.WAL.put_artifact(repo, sha, payload) do
          {:ok, _key} -> :ok
          {:error, reason} -> Logger.warning("forge artifact upload failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("forge artifact read for upload failed: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("forge artifact upload crashed: #{Exception.message(error)}")
  end

  defp record_receipt(repo, sha, target_id, modules, artifact_rel, result) do
    %BuildReceipt{}
    |> BuildReceipt.changeset(%{
      repo: repo,
      sha: sha,
      target_id: target_id,
      modules: modules,
      warnings: result.warnings,
      tests: result.tests,
      duration_ms: result.duration_ms,
      artifact: artifact_rel
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:repo, :sha, :target_id])
  end

  defp executor do
    Application.get_env(
      :openagents,
      :forge_build_executor,
      OpenAgents.Forge.BuildExecutor.Sidecar
    )
  end

  # Warm = the sidecar's incremental-build manifest exists on this node.
  # Non-sidecar executors (tests) are always "warm" — no artificial delay.
  defp warm_workspace?() do
    case executor() do
      OpenAgents.Forge.BuildExecutor.Sidecar -> OpenAgents.Forge.BuildExecutor.Sidecar.warm?()
      _other -> true
    end
  end
end
