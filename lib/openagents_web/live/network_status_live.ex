defmodule OpenAgentsWeb.NetworkStatusLive do
  @moduledoc """
  The public network status page (#125): anyone can watch the state of the
  fleet — cluster membership and quorum, per-node versions and hot-load
  revisions, and rollouts sweeping node to node — live, without an account.

  Same public posture as `LeaderboardLive` (LEADERBOARD-001): a read-only,
  bounded, content-free projection (STATUS-001) that cannot mount or invoke
  OpenAgents. Renders only `OpenAgentsWeb.UI` primitives (UI-003). Updates arrive over
  PubSub plus a slow tick; the page never requires quorum, the database, or a
  full fleet to render — it is most useful precisely when something is down.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.NetworkStatus
  alias OpenAgents.SCV.Activity
  alias OpenAgentsWeb.UI.Graph

  @tick_ms 5_000
  @events_kept 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = NetworkStatus.subscribe()
      :ok = Activity.subscribe()

      Enum.each(["forge:pushes", "forge:target", "forge:builds", "forge:deploys"], fn topic ->
        Phoenix.PubSub.subscribe(OpenAgents.PubSub, topic)
      end)

      if OpenAgents.Cluster.distributed?(), do: :net_kernel.monitor_nodes(true)
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Network status · OpenAgents")
     |> assign(:events, [])
     |> assign_projection(NetworkStatus.projection())}
  end

  @impl true
  def handle_info({:network_status, projection}, socket) do
    {:noreply, socket |> track_transitions(projection) |> assign_projection(projection)}
  end

  def handle_info({:scv_activity, entries}, socket) do
    projection =
      NetworkStatus.projection(refresh: true)
      |> Map.update("scvs", entries, &merge_scvs(&1, entries))

    {:noreply, assign_projection(socket, projection)}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    projection = NetworkStatus.projection(refresh: true)
    {:noreply, socket |> track_transitions(projection) |> assign_projection(projection)}
  end

  def handle_info({:nodeup, _node}, socket) do
    {:noreply, socket |> push_event_line("a node joined the cluster") |> refresh()}
  end

  def handle_info({:nodedown, _node}, socket) do
    {:noreply, socket |> push_event_line("a node left the cluster") |> refresh()}
  end

  # Forge deploy-lane events (#126): each transition becomes a content-free
  # event line and refreshes the projection, so a promote sweeps across the
  # pipeline card and the per-node revisions in real time.
  def handle_info({:forge_push, %{wal_seq: seq}}, socket) do
    {:noreply, socket |> push_event_line("push received (seq #{seq})") |> refresh()}
  end

  def handle_info({:forge_target, %{sha: sha}}, socket) do
    {:noreply,
     socket |> push_event_line("#{short_sha(sha)} promoted as fleet target") |> refresh()}
  end

  def handle_info({:forge_target_status, %{sha: sha, status: status}}, socket) do
    {:noreply, socket |> push_event_line("#{short_sha(sha)} → #{status}") |> refresh()}
  end

  def handle_info({:forge_build_ready, %{sha: sha, modules: modules}}, socket) do
    line = "#{short_sha(sha)} built (#{length(modules)} module#{plural(modules)})"
    {:noreply, socket |> push_event_line(line) |> refresh()}
  end

  def handle_info({:forge_deploy, %{sha: sha, result: result}}, socket) do
    {:noreply, socket |> push_event_line("hot deploy #{short_sha(sha)}: #{result}") |> refresh()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket), do: assign_projection(socket, NetworkStatus.projection(refresh: true))

  defp assign_projection(socket, projection) do
    # A briefly-cached projection built by a pre-#126 module (mid hot-load)
    # may lack the forge section — normalize rather than crash the page.
    projection =
      projection
      |> Map.put_new("forge", %{
        "state" => "off",
        "target" => nil,
        "recent_targets" => [],
        "recent_deploys" => [],
        "loop" => %{"last_ms" => nil, "median_ms" => nil}
      })
      |> Map.update(
        "scvs",
        Activity.public_projection(),
        &merge_scvs(&1, Activity.public_projection())
      )

    socket
    |> assign(:projection, projection)
    |> assign(:scvs, public_scvs(projection["scvs"]))
    |> assign(:overall, overall(projection))
  end

  defp public_scvs(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      %{
        id: entry["id"],
        label: entry["label"],
        status: public_scv_status(entry["status"]),
        weight: entry["weight"],
        tool: entry["tool"],
        text: entry["text"]
      }
    end)
  end

  defp public_scvs(_entries), do: []

  defp merge_scvs(durable_entries, live_entries) do
    entries = Map.new(durable_entries ++ live_entries, fn entry -> {entry["id"], entry} end)

    (live_entries ++ durable_entries)
    |> Enum.map(& &1["id"])
    |> Enum.uniq()
    |> Enum.take(32)
    |> Enum.map(&Map.fetch!(entries, &1))
  end

  defp public_scv_status("running"), do: :running
  defp public_scv_status(_status), do: :idle

  # Version divergence across reachable nodes IS the rollout visualization:
  # when a roll or hot deploy is sweeping the fleet, nodes disagree — surface
  # that as an explicit "rolling" state with progress.
  defp rollout(projection) do
    reachable = Enum.filter(projection["nodes"], & &1["reachable"])

    versions =
      reachable
      |> Enum.map(&{&1["release"], &1["revision"]})
      |> Enum.reject(&(&1 == {nil, nil}))
      |> Enum.uniq()

    case versions do
      [_one] ->
        :steady

      [] ->
        :steady

      _several ->
        newest = reachable |> Enum.map(& &1["revision"]) |> Enum.reject(&is_nil/1) |> List.last()
        on_newest = Enum.count(reachable, &(&1["revision"] == newest))
        {:rolling, on_newest, length(reachable)}
    end
  end

  defp overall(projection) do
    cluster = projection["cluster"]
    unreachable = Enum.count(projection["nodes"], &(!&1["reachable"]))

    cond do
      not cluster["quorum"] and cluster["beam"] > 1 -> {"degraded", "QUORUM AT RISK"}
      unreachable > 0 -> {"recovering", "NODE RECOVERING"}
      match?({:rolling, _, _}, rollout(projection)) -> {"rolling", "ROLLOUT IN PROGRESS"}
      projection["status"] == "ok" -> {"ok", "ALL SYSTEMS LIVE"}
      true -> {"degraded", "DEGRADED"}
    end
  end

  # A bounded, content-free event feed: only transitions this page itself
  # observed (no stored history), newest first.
  defp track_transitions(socket, projection) do
    previous = socket.assigns[:projection]

    cond do
      is_nil(previous) ->
        socket

      previous["cluster"] != projection["cluster"] ->
        %{"beam" => beam, "raft" => raft, "quorum" => quorum} = projection["cluster"]
        push_event_line(socket, "cluster now beam=#{beam} raft=#{raft} quorum=#{quorum}")

      revisions(previous) != revisions(projection) ->
        push_event_line(socket, "a node changed version (deploy in progress)")

      true ->
        socket
    end
  end

  defp revisions(projection),
    do: Enum.map(projection["nodes"], &{&1["release"], &1["revision"], &1["reachable"]})

  defp push_event_line(socket, line) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%H:%M:%S UTC")
    events = Enum.take([{stamp, line} | socket.assigns.events], @events_kept)
    assign(socket, :events, events)
  end

  defp uptime_text(nil), do: "—"

  defp uptime_text(seconds) when is_integer(seconds) do
    cond do
      seconds >= 86_400 -> "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"
      seconds >= 3_600 -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
      true -> "#{div(seconds, 60)}m"
    end
  end

  defp node_state(%{"reachable" => false}), do: "offline"
  defp node_state(_node), do: "connected"

  # ── forge pipeline (#126) ────────────────────────────────────────────────

  @pipeline_steps ~w(promoted building built deploying live)

  # Where the target sits in the status machine: {:progress, index} while
  # advancing, {:halted, status} on a terminal non-live state (failed,
  # reverted, needs_rolling_replace) — a revert is a story worth showing,
  # not hiding.
  defp pipeline(status) do
    case Enum.find_index(@pipeline_steps, &(&1 == status)) do
      nil -> {:halted, status}
      index -> {:progress, index}
    end
  end

  defp pipeline_steps, do: @pipeline_steps

  defp step_class(step_index, {:progress, at}) do
    cond do
      step_index < at ->
        "status-pipeline__step status-pipeline__step--done"

      step_index == at and at == length(@pipeline_steps) - 1 ->
        "status-pipeline__step status-pipeline__step--done"

      step_index == at ->
        "status-pipeline__step status-pipeline__step--active"

      true ->
        "status-pipeline__step"
    end
  end

  defp step_class(_step_index, {:halted, _status}), do: "status-pipeline__step"

  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
  defp short_sha(_sha), do: "—"

  defp plural([_one]), do: ""
  defp plural(_modules), do: "s"

  defp ms_text(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)}s"
  defp ms_text(_ms), do: "—"

  defp mirror_text(%{"state" => "current"}), do: "current"

  defp mirror_text(%{"state" => "lagging", "lagging_minutes" => minutes}),
    do: "lagging #{minutes}m"

  defp mirror_text(_state), do: "off"

  defp deploy_result_variant("live"), do: :success
  defp deploy_result_variant("reverted"), do: :warning
  defp deploy_result_variant("needs_rolling_replace"), do: :warning
  defp deploy_result_variant(_result), do: :danger

  defp overall_badge_variant("ok"), do: :success
  defp overall_badge_variant("rolling"), do: :info
  defp overall_badge_variant("recovering"), do: :warning
  defp overall_badge_variant(_state), do: :error

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Status"
    >
      <main id="network-status-page" class="app-shell status-shell">
        <section class="status" aria-label="Network status">
          <header class="status-heading">
            <div>
              <h1>Network status</h1>
              <p>
                The OpenAgents fleet — a quorum cluster that survives node loss and
                upgrades in place. Owned sessions dropped per node loss or
                upgrade: 0; the release gate refuses anything that breaks that.
              </p>
            </div>
            <.badge id="status-overall" variant={overall_badge_variant(elem(@overall, 0))}>
              <.status_indicator state={elem(@overall, 0)} label={elem(@overall, 1)} decorative />
              {elem(@overall, 1)}
            </.badge>
          </header>

          <.card id="status-cluster">
            <div class="status-metrics">
              <div class="status-metric">
                <span class="status-metric__value">{@projection["cluster"]["beam"]}</span>
                <span class="status-metric__label">BEAM nodes</span>
              </div>
              <div class="status-metric">
                <span class="status-metric__value">{@projection["cluster"]["raft"]}</span>
                <span class="status-metric__label">Raft members</span>
              </div>
              <div class="status-metric">
                <span class="status-metric__value">
                  {if @projection["cluster"]["quorum"], do: "held", else: "lost"}
                </span>
                <span class="status-metric__label">quorum</span>
              </div>
              <div class="status-metric">
                <span class="status-metric__value">
                  {@projection["counts"]["machines_connected"] || "—"}
                </span>
                <span class="status-metric__label">computers connected</span>
              </div>
              <div class="status-metric">
                <span class="status-metric__value">{@projection["counts"]["active_jobs"] || "—"}</span>
                <span class="status-metric__label">active jobs</span>
              </div>
            </div>
          </.card>

          <.alert
            :if={match?({:rolling, _, _}, rollout(@projection))}
            id="status-rollout"
            variant={:info}
            title="Rollout in progress"
          >
            <% {:rolling, done, total} = rollout(@projection) %> Nodes are moving to a new version one at a time — {done}/{total} on the
            newest build. The cluster never drops below quorum during a roll.
          </.alert>

          <.card id="status-scvs">
            <h2>Active SCVs</h2>
            <p class="status-forge__intro">
              Follow the bounded public activity from SCVs that are running now.
              Prompts, repository paths, command arguments, tool output, and reports
              stay private.
            </p>

            <.empty :if={@scvs == []} id="status-no-scvs" title="No active SCVs">
              The next admitted SCV run will appear here as it works.
            </.empty>

            <Graph.scv_streams
              :if={@scvs != []}
              id="public-scv-streams"
              scvs={@scvs}
            />
          </.card>

          <div id="status-nodes" class="status-nodes">
            <.card
              :for={{node, index} <- Enum.with_index(@projection["nodes"])}
              id={"status-node-#{index}"}
            >
              <div class="status-node">
                <div class="status-node__head">
                  <.status_indicator
                    state={node_state(node)}
                    label={if node["reachable"], do: "reachable", else: "unreachable"}
                  />
                  <strong>{node["label"]}</strong>
                </div>
                <dl :if={node["reachable"]} class="status-node__facts">
                  <div>
                    <dt>release</dt><dd>{node["release"] || "—"}</dd>
                  </div>
                  <div>
                    <dt>revision</dt><dd>{node["revision"] || "—"}</dd>
                  </div>
                  <div :if={node["hot_loaded_at"]}>
                    <dt>hot-loaded</dt><dd>{node["hot_loaded_at"]}</dd>
                  </div>
                  <div>
                    <dt>uptime</dt><dd>{uptime_text(node["uptime_seconds"])}</dd>
                  </div>
                  <div>
                    <dt>sees</dt><dd>beam={node["beam_seen"]} raft={node["raft_seen"]}</dd>
                  </div>
                </dl>
                <p :if={!node["reachable"]} class="status-node__facts">
                  Not answering — rebooting or being replaced. The survivors hold
                  quorum and its work relocates to them.
                </p>
              </div>
            </.card>
          </div>

          <.card id="status-forge">
            <div class="status-node__head">
              <h2>Rapid deploys</h2>
              <.badge
                id="status-forge-state"
                variant={if @projection["forge"]["state"] == "active", do: :success, else: :warning}
              >
                {@projection["forge"]["state"]}
              </.badge>
            </div>
            <p class="status-forge__intro">
              Code moves through the OpenAgents forge: a push is promoted by an
              operator, built into just the changed modules, and hot-loaded
              across the fleet without a restart — watch it sweep the nodes
              above.
            </p>

            <.empty
              :if={is_nil(@projection["forge"]["target"])}
              id="status-forge-empty"
              title="No deploys yet"
            >
              The next promoted commit will appear here as it rolls out.
            </.empty>

            <div :if={target = @projection["forge"]["target"]} class="status-forge__target">
              <% position = pipeline(target["status"]) %>
              <ol class="status-pipeline" aria-label="Deploy pipeline">
                <li
                  :for={{step, index} <- Enum.with_index(pipeline_steps())}
                  class={step_class(index, position)}
                >
                  {step}
                </li>
              </ol>

              <div class="status-forge__facts">
                <span><code>{target["sha"]}</code></span>
                <.badge
                  :if={match?({:halted, _}, position)}
                  id="status-forge-halted"
                  variant={deploy_result_variant(target["status"])}
                >
                  {target["status"]}
                </.badge>
                <span>promoted by {target["promoted_by"] || "—"}</span>
                <span :if={target["modules"] > 0}>
                  {target["modules"]} module{if target["modules"] == 1, do: "", else: "s"}
                </span>
              </div>

              <div class="status-metrics status-forge__loop">
                <div class="status-metric">
                  <span class="status-metric__value">
                    {ms_text(@projection["forge"]["loop"]["last_ms"])}
                  </span>
                  <span class="status-metric__label">last push→live</span>
                </div>
                <div class="status-metric">
                  <span class="status-metric__value">
                    {ms_text(@projection["forge"]["loop"]["median_ms"])}
                  </span>
                  <span class="status-metric__label">median push→live</span>
                </div>
              </div>
            </div>

            <p class="status-forge__intro" id="status-forge-mirror">
              mirror: {mirror_text(@projection["forge"]["mirror"])}
            </p>

            <p class="status-forge__intro" id="status-forge-policy">
              deploy policy: direct hot load → relup → rolling replacement
            </p>

            <div :if={@projection["forge"]["recent_deploys"] != []} class="status-forge__history">
              <h3>Recent deploys</h3>
              <ul class="status-events">
                <li :for={deploy <- @projection["forge"]["recent_deploys"]}>
                  <span class="status-events__stamp"><code>{deploy["sha"]}</code></span>
                  <.badge variant={deploy_result_variant(deploy["result"])}>
                    {deploy["result"]}
                  </.badge>
                  {deploy["modules"]} module{if deploy["modules"] == 1, do: "", else: "s"} · push→live {ms_text(
                    deploy["push_to_live_ms"]
                  )}
                </li>
              </ul>
            </div>
          </.card>

          <.card id="status-events">
            <h2>Live events</h2>
            <.empty :if={@events == []} id="status-no-events" title="Quiet">
              No transitions observed since you opened this page.
            </.empty>
            <ul :if={@events != []} class="status-events">
              <li :for={{stamp, line} <- @events}>
                <span class="status-events__stamp">{stamp}</span> {line}
              </li>
            </ul>
          </.card>

          <footer class="status-footer">
            <p>
              Machine-readable: <code>GET /api/status</code>
              (schema <code>openagents.network_status.v1</code>) ·
              probe: <code>GET /health</code>. This page updates live.
            </p>
          </footer>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
