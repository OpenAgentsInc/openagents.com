defmodule OpenAgentsWeb.ChangelogLive do
  @moduledoc """
  The public changelog (#138, spec §3): two layers over one timeline — a
  human note per change, and an expandable agent layer with the receipt
  chain (sha, modules, measured push→live, deploy result, provenance).

  Same public posture as the leaderboard and status pages (UI-001 lineage,
  TRANSPARENCY-001): read-only, mounts without a session, cannot invoke
  OpenAgents, renders only `OpenAgentsWeb.UI` primitives (UI-003), and updates live
  off the forge PubSub — a hot-load appears here seconds after it lands.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Changelog

  @repo "openagents.com"
  @forge_topics ["forge:pushes", "forge:target", "forge:builds", "forge:deploys"]

  @impl true
  def mount(_params, _session, socket) do
    rows =
      case Changelog.timeline(@repo) do
        {:ok, rows} -> rows
        {:error, :not_public} -> raise OpenAgentsWeb.PublicNotFoundError
      end

    if connected?(socket) do
      Enum.each(@forge_topics, &Phoenix.PubSub.subscribe(OpenAgents.PubSub, &1))
    end

    {:ok,
     socket
     |> assign(:page_title, "Changelog · OpenAgents")
     |> assign(:repo, @repo)
     |> assign(:base, OpenAgents.Forge.Visibility.repo_path(@repo) || "")
     |> assign(:rows, rows)
     |> assign(:filter, nil)}
  end

  @impl true
  def handle_event("filter", %{"category" => category}, socket) do
    filter = if category == socket.assigns.filter, do: nil, else: category
    {:noreply, assign(socket, :filter, filter)}
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
    case Changelog.timeline(@repo, refresh: true) do
      {:ok, rows} -> {:noreply, assign(socket, :rows, rows)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp visible_rows(rows, nil), do: rows
  defp visible_rows(rows, filter), do: Enum.filter(rows, &(&1.category == filter))

  defp categories_present(rows) do
    rows |> Enum.map(& &1.category) |> Enum.uniq() |> Enum.sort()
  end

  defp category_variant("ui"), do: :info
  defp category_variant("fix"), do: :warning
  defp category_variant("incident"), do: :danger
  defp category_variant("forge"), do: :success
  defp category_variant(_), do: :default

  defp result_variant("live"), do: :success
  defp result_variant("reverted"), do: :danger
  defp result_variant("failed"), do: :danger
  defp result_variant(_), do: :warning

  defp stamp(nil), do: "—"

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp ms_text(nil), do: "—"
  defp ms_text(ms) when ms < 1_000, do: "#{ms} ms"
  defp ms_text(ms), do: "#{Float.round(ms / 1_000, 1)} s"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="changelog-page" class="app-shell changelog-shell">
        <Layouts.command_bar aria_label="OpenAgents changelog" current_user={@current_user}>
          <:lockup>
            <.button
              :if={@current_user}
              id="return-to-conversation"
              variant={:chip}
              size={:xs}
              phx-click={JS.navigate(~p"/chat")}
            >
              <.icon name="arrow-left" /> RETURN TO CONVERSATION
            </.button>
          </:lockup>
        </Layouts.command_bar>

        <section class="changelog" aria-label="Changelog">
          <header class="changelog-heading">
            <div>
              <h1>Changelog</h1>
              <p>
                Every change to OpenAgents, two layers deep: what changed in plain
                words, and — expand any entry — the receipts: the commit, the
                modules hot-loaded, and the measured push→live time. OpenAgents
                ships her own code through her own forge; this page is how
                you watch her do it.
              </p>
            </div>
          </header>

          <div class="changelog-filters" role="group" aria-label="Filter by category">
            <.button
              :for={category <- categories_present(@rows)}
              id={"changelog-filter-#{category}"}
              variant={:chip}
              size={:xs}
              phx-click="filter"
              phx-value-category={category}
              aria-pressed={to_string(@filter == category)}
            >
              {category}
            </.button>
          </div>

          <.empty :if={@rows == []} id="changelog-empty" title="Nothing yet">
            The first receipted change will appear here as it ships.
          </.empty>

          <ol class="changelog-rows" aria-label="Changes, newest first">
            <li :for={{row, index} <- Enum.with_index(visible_rows(@rows, @filter))}>
              <.card id={"changelog-row-#{index}"}>
                <div class="changelog-row__head">
                  <.badge variant={category_variant(row.category)}>{row.category}</.badge>
                  <span class="changelog-row__stamp">{stamp(row.entry_at)}</span>
                  <.badge :if={row.deploy} variant={result_variant(row.deploy.result)}>
                    {row.deploy.result}
                  </.badge>
                </div>

                <p :if={row.summary} class="changelog-row__summary">{row.summary}</p>
                <p
                  :if={is_nil(row.summary)}
                  class="changelog-row__summary changelog-row__summary--bare"
                >
                  Receipted deploy of <code>{row.short_sha}</code> — no release note was written.
                </p>

                <details class="changelog-row__detail">
                  <summary>detail</summary>
                  <dl class="changelog-facts">
                    <div :if={row.short_sha}>
                      <dt>commit</dt>
                      <dd>
                        <.text_button navigate={"#{@base}/commit/#{row.short_sha}"}>
                          <code>{row.short_sha}</code>
                        </.text_button>
                      </dd>
                    </div>
                    <div :if={row.deploy}>
                      <dt>push→live</dt>
                      <dd>{ms_text(row.deploy.push_to_live_ms)}</dd>
                    </div>
                    <div :if={row.deploy}>
                      <dt>modules</dt>
                      <dd>{row.deploy.modules} on {row.deploy.nodes} nodes</dd>
                    </div>
                    <div :if={row.push}>
                      <dt>pushed by</dt>
                      <dd>{row.push.principal_role} (wal seq {row.push.wal_seq})</dd>
                    </div>
                    <div :if={row.build}>
                      <dt>build</dt>
                      <dd>{ms_text(row.build.duration_ms)}, {row.build.modules} modules</dd>
                    </div>
                    <div>
                      <dt>source</dt>
                      <dd>{row.source}</dd>
                    </div>
                    <div :if={row.trace_digest}>
                      <dt>trace digest</dt>
                      <dd><code>{row.trace_digest}</code></dd>
                    </div>
                  </dl>
                </details>
              </.card>
            </li>
          </ol>

          <footer class="changelog-footer">
            <p>
              Machine-readable: <code>GET /api/changelog</code>
              (schema <code>{Changelog.schema_version()}</code>) ·
              <.text_button navigate={"#{@base}/blob/main/CHANGELOG.md"}>
                this changelog as a document
              </.text_button>
              · <.text_button navigate="/status">fleet status</.text_button>.
              Entries are projections; the receipt chain is the authority.
            </p>
          </footer>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
