defmodule OpenAgents.Forge.HotLoader do
  @moduledoc """
  Hot-load lane (roadmap P4): applies built beam artifacts to the running
  fleet without a restart.

  Listens on `forge:builds` for build-ready broadcasts and, serially per
  build: refuses any artifact touching a module off the operator-owned
  hot-load allowlist (honest `needs_rolling_replace`, never a partial load),
  canaries the load on the local node with revert-on-failure, then
  `:erpc.multicall`s the rest of the fleet. Every outcome — `live`,
  `reverted`, `needs_rolling_replace`, `failed` — lands as a
  `forge_deploys` receipt including the measured push→live duration, and
  the target row advances honestly at each step.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.DeployReceipt
  alias OpenAgents.Forge.PushReceipt
  alias OpenAgents.Forge.Targets
  alias OpenAgents.Repo

  @builds_topic "forge:builds"
  @deploys_topic "forge:deploys"
  @default_allowlist ["OpenAgents.Scratch.", "OpenAgents.BuildInfo"]
  @fleet_timeout_ms 15_000

  # ── api ──────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Load a set of `{module, beam_binary}` pairs on this node. Public because
  the canary node calls it on the rest of the fleet via `:erpc.multicall`
  (no remote revert logic in v0 — per-node results are recorded instead).
  """
  def load_beams(beams) do
    Enum.map(beams, fn {mod, binary} ->
      case :code.load_binary(mod, ~c"forge-hot-load", binary) do
        {:module, ^mod} -> {mod, :ok}
        {:error, reason} -> {mod, {:error, reason}}
      end
    end)
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
      with {:ok, verified} <-
             BuildArtifact.verify_file(build.artifact,
               digest: Map.get(build, :artifact_digest),
               repo: repo,
               source_sha: sha,
               build_id: Map.get(build, :build_id)
             ),
           true <- verified.modules == modules or {:error, :declared_modules_mismatch},
           true <-
             is_nil(Map.get(build, :manifest)) or Map.get(build, :manifest) == verified.manifest or
               {:error, :declared_manifest_mismatch} do
        route_verified(build, verified)
      else
        {:error, reason} -> fail_verified_build(build, reason)
      end
    end
  rescue
    error ->
      message = "hot_load_failed code=" <> OpenAgents.OperationalLog.code(error)
      Logger.error("forge_hot_load_failed code=#{OpenAgents.OperationalLog.code(error)}")
      advance(target_id, "failed", %{"error" => message})
      insert_receipt(repo, sha, target_id, modules, [], "failed", nil, nil)
      broadcast_deploy(repo, sha, "failed")
  catch
    :refused -> :ok
  end

  defp route_verified(build, verified) do
    allowlist = Application.get_env(:openagents, :forge_hot_load_allowlist, @default_allowlist)
    offending = Enum.reject(verified.modules, &allowlisted?(&1, allowlist))

    cond do
      verified.manifest["classification"] != "direct_candidate" ->
        route_rolling(build, verified.manifest["structural_reasons"])

      offending != [] ->
        route_rolling(build, Enum.map(offending, &"off_allowlist:#{&1}"))

      true ->
        deploy(build, verified)
    end
  end

  defp route_rolling(%{repo: repo, sha: sha, target_id: target_id, modules: modules}, reasons) do
    case advance(target_id, "needs_rolling_replace", %{
           "modules" => modules,
           "reasons" => reasons
         }) do
      :ok ->
        insert_receipt(repo, sha, target_id, modules, [], "needs_rolling_replace", nil, nil)
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
    insert_receipt(repo, sha, target_id, modules, [], "failed", nil, nil)
    broadcast_deploy(repo, sha, "failed")
  end

  defp deploy(%{repo: repo, sha: sha, target_id: target_id, modules: modules}, verified) do
    case advance(target_id, "deploying") do
      :ok -> :ok
      :error -> throw(:refused)
    end

    # Atom creation happens only here, after the full tar and manifest have
    # passed every bounded identity and classification check.
    beams =
      Enum.map(verified.beams, fn %{module: module, binary: binary} ->
        {BuildArtifact.module_atom(module), binary}
      end)

    case canary_load(beams) do
      :ok ->
        nodes = fleet_load(beams)
        advance(target_id, "live", %{"modules" => modules})
        push_ms = push_to_live_ms(repo, sha)
        insert_receipt(repo, sha, target_id, modules, nodes, "live", "ok", push_ms)
        broadcast_deploy(repo, sha, "live")

      {:error, reason} ->
        advance(target_id, "reverted", %{"error" => bounded(reason)})
        insert_receipt(repo, sha, target_id, modules, [], "reverted", bounded(reason), nil)
        broadcast_deploy(repo, sha, "reverted")
    end
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

  # ── canary (local node, revert on any failure) ───────────────────────────

  defp canary_load(beams), do: canary_load(beams, [])

  defp canary_load([], loaded) do
    case smoke_check(loaded) do
      :ok ->
        :ok

      {:error, reason} ->
        revert(loaded)
        {:error, reason}
    end
  end

  defp canary_load([{mod, binary} | rest], loaded) do
    # Keep the currently loaded object code so a later failure can revert.
    previous = :code.get_object_code(mod)

    case :code.load_binary(mod, ~c"forge-hot-load", binary) do
      {:module, ^mod} ->
        canary_load(rest, [{mod, previous} | loaded])

      {:error, reason} ->
        revert(loaded)
        {:error, "canary load of #{inspect(mod)} failed: #{inspect(reason)}"}
    end
  end

  defp smoke_check(loaded) do
    Enum.reduce_while(loaded, :ok, fn {mod, _previous}, :ok ->
      cond do
        not Code.ensure_loaded?(mod) ->
          {:halt, {:error, "smoke check: #{inspect(mod)} not loaded"}}

        function_exported?(mod, :revision, 0) and not revision_binary?(mod) ->
          {:halt, {:error, "smoke check: #{inspect(mod)}.revision/0 did not return a binary"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp revision_binary?(mod) do
    is_binary(mod.revision())
  rescue
    _ -> false
  end

  defp revert(loaded) do
    Enum.each(loaded, fn
      {mod, {_mod, binary, file}} ->
        :code.load_binary(mod, file, binary)

      {mod, :error} ->
        # Was not loaded before this deploy: remove it entirely.
        :code.purge(mod)
        :code.delete(mod)
    end)
  end

  # ── fleet ────────────────────────────────────────────────────────────────

  defp fleet_load(beams) do
    remote =
      case Node.list() do
        [] ->
          []

        nodes ->
          nodes
          |> Enum.zip(:erpc.multicall(nodes, __MODULE__, :load_beams, [beams], @fleet_timeout_ms))
          |> Enum.map(fn
            {node, {:ok, results}} ->
              if Enum.all?(results, &match?({_mod, :ok}, &1)),
                do: "#{node}=ok",
                else: "#{node}=error"

            {node, _failure} ->
              "#{node}=error"
          end)
      end

    ["#{Node.self()}=ok" | remote]
  end

  # ── receipts ─────────────────────────────────────────────────────────────

  # Push→live duration: the push receipt whose refs advanced some ref to
  # this sha marks when the loop started.
  defp push_to_live_ms(repo, sha) do
    PushReceipt
    |> where([p], p.repo == ^repo)
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

  defp insert_receipt(repo, sha, target_id, modules, nodes, result, canary, push_ms) do
    %DeployReceipt{}
    |> DeployReceipt.changeset(%{
      repo: repo,
      sha: sha,
      target_id: target_id,
      modules: modules,
      nodes: nodes,
      result: result,
      canary: canary,
      push_to_live_ms: push_ms
    })
    |> Repo.insert()
  rescue
    error ->
      Logger.error("forge_deploy_receipt_failed code=#{OpenAgents.OperationalLog.code(error)}")
      :error
  end

  defp advance(target_id, status, details \\ %{}) do
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
