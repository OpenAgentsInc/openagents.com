defmodule OpenAgentsWeb.AdminForgeLive do
  @moduledoc """
  The forge deploy panel: recent pushes, the current fleet target and its
  deploy-lane status, deploy receipts with the push→live loop time, and the
  one write the operator surface permits — **Promote** (ADMIN-001 as amended
  2026-08-18): approving an already-pushed commit as the fleet target,
  receipted with the operator's identity. Only WAL-pushed SHAs are
  promotable; everything else here is a read-only projection that updates
  live off the forge PubSub topics.
  """

  use OpenAgentsWeb, :sarah_live_view

  alias OpenAgents.Accounts
  alias OpenAgents.Forge
  alias OpenAgents.Forge.Targets

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      if connected?(socket) do
        Enum.each(["forge:pushes", "forge:target", "forge:builds", "forge:deploys"], fn topic ->
          Phoenix.PubSub.subscribe(OpenAgents.PubSub, topic)
        end)
      end

      {:ok,
       socket
       |> assign(:page_title, "Operator · Forge")
       |> assign(:repo, primary_repo())
       |> load()}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("promote", %{"sha" => sha}, socket) do
    unless Accounts.admin?(socket.assigns.current_user) do
      {:noreply, redirect(socket, to: ~p"/")}
    else
      operator = "operator:" <> to_string(socket.assigns.current_user.github_id)

      socket =
        case Targets.promote(socket.assigns.repo, sha, operator, commit_store: &git_store/2) do
          {:ok, _target} ->
            put_flash(socket, :info, "Promoted #{String.slice(sha, 0, 12)} as the fleet target.")

          {:error, :unknown_sha} ->
            put_flash(
              socket,
              :error,
              "That commit is not in the forge — only pushed commits are promotable."
            )

          {:error, _reason} ->
            put_flash(socket, :error, "Promotion failed.")
        end

      {:noreply, load(socket)}
    end
  end

  @impl true
  def handle_info(message, socket)
      when elem(message, 0) in [
             :forge_push,
             :forge_target,
             :forge_target_status,
             :forge_build_ready,
             :forge_deploy
           ] do
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    repo = socket.assigns.repo

    socket
    |> assign(:pushes, Forge.recent_pushes(repo))
    |> assign(:target, Targets.current(repo))
    |> assign(:targets, Targets.recent(repo))
    |> assign(:deploys, Forge.recent_deploys(repo))
  end

  defp primary_repo do
    OpenAgents.Forge.Repos.allowed_repos() |> List.first() || "sarah"
  end

  defp git_store(repo, sha) do
    OpenAgents.Forge.Sync.ensure_fresh(repo)
    path = OpenAgents.Forge.Repos.bare_path(repo)

    case OpenAgents.Forge.Repos.git(path, ["cat-file", "-e", sha <> "^{commit}"]) do
      {_, 0} -> :ok
      _ -> :error
    end
  end

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
  defp short(_), do: "—"

  defp loop_time(nil), do: "—"
  defp loop_time(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)}s"
  defp loop_time(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="admin-forge-page" class="app-shell admin-shell">
        <section class="admin" aria-label="Forge deploy lane">
          <h1>Forge — {@repo}</h1>

          <div class="admin-totals" aria-label="Current fleet target">
            <div :if={@target}>
              <strong>Target:</strong> {short(@target.sha)} · {@target.status}
              <span :if={@target.details != %{}}>· {inspect(
                Map.take(@target.details, ~w(error modules))
              )}</span>
              <span> · promoted by {@target.promoted_by}</span>
            </div>
            <div :if={is_nil(@target)}>No fleet target promoted yet.</div>
          </div>

          <h2>Recent pushes</h2>
          <div :if={@pushes == []}>No pushes yet — the forge is seeded by the first push.</div>
          <div :for={push <- @pushes} class="admin-row" id={"push-#{push.wal_seq}"}>
            <div class="admin-identity">
              seq {push.wal_seq} · {push.principal} · {Enum.map_join(push.refs, ", ", fn {name,
                                                                                          change} ->
                "#{name} → #{short(change["new"])}"
              end)}
            </div>
            <div class="admin-state">
              <button
                :for={{_name, %{"new" => sha}} <- Enum.take(push.refs, 1)}
                :if={is_binary(sha)}
                phx-click="promote"
                phx-value-sha={sha}
              >
                Promote {short(sha)}
              </button>
            </div>
          </div>

          <h2>Deploys</h2>
          <div :if={@deploys == []}>No deploys yet.</div>
          <div :for={deploy <- @deploys} class="admin-row" id={"deploy-#{deploy.id}"}>
            <div class="admin-identity">
              {short(deploy.sha)} · {deploy.result} · modules {length(deploy.modules)} ·
              push→live {loop_time(deploy.push_to_live_ms)}
            </div>
          </div>

          <h2>Target history</h2>
          <div :for={target <- @targets} class="admin-row" id={"target-#{target.id}"}>
            <div class="admin-identity">
              {short(target.sha)} · {target.status} · {target.promoted_by}
            </div>
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
