defmodule OpenAgents.NetworkStatus do
  @moduledoc """
  The one bounded, content-free projection of the network's state (#125,
  INVARIANTS.md STATUS-001) — what the public `/status` page and
  `/api/status` publish.

  Assembled from the serving node's own view plus a bounded concurrent
  `:erpc` fan-out to its peers (short timeout each): cluster membership and
  quorum (`OpenAgents.Cluster`), Raft membership (`OpenAgents.Cluster.Ra`), and per-node
  release version, hot-load revision (`OpenAgents.BuildInfo`), relup marker, and
  uptime. Public SCV activity includes only a pseudonymous label, lifecycle
  state, admitted tool category, and normalized action. Connected controller
  machines and active work jobs remain counts only. No names, goals, internal
  ids, addresses, prompts, repository paths, tool output, or reports appear.

  Honesty rules the shape:
  - A peer that does not answer in time renders `"unreachable"` — the page
    must render DURING incidents, so nothing here requires quorum, the DB,
    or a full fleet. Every gather degrades per-field to `nil`/`"unknown"`.
  - Node names carry internal addresses, so the projection replaces them
    with stable positional labels ("node 1"..., sorted by name).

  The fan-out result is cached briefly so page traffic cannot cause an rpc
  storm, and `broadcast/0`/`subscribe/0` push refreshes over PubSub (node
  up/down and the status page's slow tick call `broadcast/0`).
  """

  @schema "openagents.network_status.v1"
  @topic "network_status"
  @cache_key {__MODULE__, :cache}
  @cache_ms 2_000
  @rpc_timeout_ms 1_500

  @doc "Subscribe to projection refreshes (`{:network_status, projection}`)."
  def subscribe, do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, @topic)

  @doc "Recompute and push the projection to subscribers."
  def broadcast do
    projection = projection(refresh: true)
    Phoenix.PubSub.broadcast(OpenAgents.PubSub, @topic, {:network_status, projection})
    projection
  end

  @doc "The current projection (briefly cached; `refresh: true` bypasses)."
  def projection(opts \\ []) do
    now = System.monotonic_time(:millisecond)

    case {Keyword.get(opts, :refresh, false), :persistent_term.get(@cache_key, nil)} do
      {false, {at, cached}} when now - at < @cache_ms ->
        cached

      _stale ->
        fresh = build()
        :persistent_term.put(@cache_key, {now, fresh})
        fresh
    end
  end

  defp build do
    cluster = safely(fn -> OpenAgents.Cluster.snapshot() end) || %{}
    beam_nodes = Enum.sort([node() | Node.list()])
    raft = safely(fn -> length(OpenAgents.Cluster.Ra.members()) end) || 0
    # Quorum against the CONFIGURED fleet size (a partitioned minority must
    # not report itself healthy). Where Ra is off (single-node Cloud Run) the
    # expected size is honestly 1.
    expected =
      cond do
        Application.get_env(:openagents, :ra_enabled, false) ->
          Application.get_env(:openagents, :ra_expected_size, 3)

        Application.get_env(:openagents, :forge_deploy_lane_enabled, false) ->
          Application.get_env(:openagents, :forge_expected_fleet_size, 1)

        true ->
          1
      end

    quorum = safely(fn -> OpenAgents.Cluster.quorum?(max(expected, 1)) end) || false

    nodes =
      beam_nodes
      |> Task.async_stream(&node_report/1,
        timeout: @rpc_timeout_ms + 500,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(beam_nodes)
      |> Enum.with_index(1)
      |> Enum.map(fn {{result, _node}, index} ->
        report =
          case result do
            {:ok, report} -> report
            _timeout_or_exit -> %{"reachable" => false}
          end

        # Positional label only: node names carry internal addresses, which
        # never leave the server (STATUS-001).
        Map.put(report, "label", "node #{index}")
      end)

    nodes_ready? = Enum.all?(nodes, &(&1["reachable"] == true and &1["ready"] == true))

    %{
      "schema" => @schema,
      # Legacy /status compatibility keys — pollers migrating from the old
      # payload find them here unchanged.
      "status" => if(quorum and nodes_ready?, do: "ok", else: "degraded"),
      "revision" => safely(fn -> OpenAgents.Forge.DeploymentNode.health()["revision"] end),
      "cluster" => %{
        "distributed" => Map.get(cluster, "distributed", false),
        "beam" => length(beam_nodes),
        "raft" => raft,
        "quorum" => quorum
      },
      "nodes" => nodes,
      "counts" => counts(),
      "scvs" => scv_projection(),
      "forge" => forge_section(),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # ── forge deploy lane (#126) ─────────────────────────────────────────────
  #
  # The public projection of the rapid-deploy pipeline: current fleet target
  # with its status-machine position, bounded recent history, and the
  # headline loop metric (push→live). Content-free per STATUS-001: short
  # shas, statuses, timings, and module COUNTS only — never commit messages,
  # build output, module names, or the operator's identity (the role prefix
  # of `promoted_by` is public; the id after `:` stays on /admin/forge).
  # Every read degrades to nil/[] — forge disabled or DB down renders as
  # "no deploys yet", never an error.
  defp forge_section do
    repo =
      safely(fn -> List.first(OpenAgents.Forge.Repos.allowed_repos()) end) || "openagents.com"

    targets = safely(fn -> OpenAgents.Forge.Targets.recent(repo, 10) end) || []
    deploys = safely(fn -> OpenAgents.Forge.recent_deploys(repo, 10) end) || []

    live_times =
      for deploy <- deploys, deploy.result == "live", is_integer(deploy.push_to_live_ms) do
        deploy.push_to_live_ms
      end

    %{
      "repo" => repo,
      "state" =>
        if(Application.get_env(:openagents, :forge_deploy_lane_enabled, false),
          do: "active",
          else: "off"
        ),
      "target" => targets |> List.first() |> public_target(),
      "recent_targets" => Enum.map(targets, &public_target/1),
      "recent_deploys" => Enum.map(deploys, &public_deploy/1),
      "loop" => %{
        "last_ms" => List.first(live_times),
        "median_ms" => median(live_times)
      },
      "mirror" => safely(fn -> OpenAgents.Forge.MirrorWatch.state() end) || %{"state" => "off"}
    }
  end

  defp public_target(nil), do: nil

  defp public_target(target) do
    %{
      "sha" => short_sha(target.sha),
      "status" => target.status,
      "promoted_by" => public_role(target.promoted_by),
      "promoted_at" => DateTime.to_iso8601(target.inserted_at),
      "updated_at" => DateTime.to_iso8601(target.updated_at),
      "modules" => target.details |> Map.get("modules", []) |> length()
    }
  end

  defp public_deploy(deploy) do
    %{
      "sha" => short_sha(deploy.sha),
      "result" => deploy.result,
      "modules" => length(deploy.modules),
      "push_to_live_ms" => deploy.push_to_live_ms,
      "at" => DateTime.to_iso8601(deploy.inserted_at)
    }
  end

  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
  defp short_sha(_sha), do: nil

  # "operator:<github_id>" → "operator" — the role is public, the id is not.
  defp public_role(promoted_by) when is_binary(promoted_by),
    do: promoted_by |> String.split(":", parts: 2) |> hd()

  defp public_role(_promoted_by), do: nil

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted) - 1, 2))
  end

  # Everything a node publicly reports about itself. Runs ON that node (via
  # the fan-out); every field degrades independently.
  @doc false
  def node_report(target) when target == node(), do: local_report()

  def node_report(target) do
    case :erpc.call(target, __MODULE__, :local_report, [], @rpc_timeout_ms) do
      %{} = report -> report
      _other -> %{"reachable" => false}
    end
  rescue
    _error -> %{"reachable" => false}
  catch
    _kind, _reason -> %{"reachable" => false}
  end

  @doc false
  def local_report do
    {wall_ms, _} = :erlang.statistics(:wall_clock)
    boot = OpenAgents.Forge.BootConverge.state()
    boot_ready? = OpenAgents.Forge.BootConverge.ready?()
    deployment = OpenAgents.Forge.DeploymentNode.health()

    %{
      "reachable" => true,
      "ready" => boot_ready? and deployment["ready"] == true,
      "release" => safely(fn -> permanent_release_version() end),
      "revision" => deployment["revision"] || boot["sha"] || OpenAgents.BuildInfo.revision(),
      "hot_loaded_at" => safely(fn -> OpenAgents.BuildInfo.loaded_at() end),
      "marker" => safely(fn -> OpenAgents.Cluster.relup_marker() end),
      "boot" => %{
        "state" => boot["state"],
        "ready" => boot_ready?,
        "reason" => boot["reason"],
        "attempts" => boot["attempts"],
        "retry_in_ms" => boot["retry_in_ms"]
      },
      "deployment" => %{
        "ready" => deployment["participant_ready"],
        "phase" => deployment["phase"],
        "reason" => deployment["reason"]
      },
      "uptime_seconds" => div(wall_ms, 1_000),
      "beam_seen" => 1 + length(Node.list()),
      "raft_seen" => safely(fn -> length(OpenAgents.Cluster.Ra.members()) end) || 0
    }
  end

  defp permanent_release_version do
    :release_handler.which_releases()
    |> Enum.find_value(fn
      {_name, vsn, _libs, :permanent} -> List.to_string(vsn)
      _other -> nil
    end)
  rescue
    # No release (dev/test runs on Mix): the app version is the truth.
    _ -> to_string(Application.spec(:openagents, :vsn))
  catch
    _, _ -> to_string(Application.spec(:openagents, :vsn))
  end

  # Counts only — no names, goals, or ids (STATUS-001). Each degrades to nil
  # rather than failing the projection (the page renders with the DB down).
  defp counts do
    %{
      "machines_connected" =>
        safely(fn ->
          OpenAgents.HordeRegistry
          |> Horde.Registry.select([{{{:machine, :_}, :_, :_}, [], [true]}])
          |> length()
        end),
      "active_jobs" =>
        safely(fn ->
          import Ecto.Query

          OpenAgents.Repo.aggregate(
            from(j in OpenAgents.Work.Job, where: j.status in ~w(queued running)),
            :count
          )
        end)
    }
  end

  # Live events make the local UI responsive. Durable rows make the same SCV
  # visible from every serving node. Prefer the live entry when both exist.
  defp scv_projection do
    durable = safely(fn -> OpenAgents.SCV.Executions.public_projection() end) || []
    live = safely(fn -> OpenAgents.SCV.Activity.public_projection() end) || []

    entries = Map.new(durable ++ live, fn entry -> {entry["id"], entry} end)

    (live ++ durable)
    |> Enum.map(& &1["id"])
    |> Enum.uniq()
    |> Enum.take(32)
    |> Enum.map(&Map.fetch!(entries, &1))
  end

  defp safely(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end
end
