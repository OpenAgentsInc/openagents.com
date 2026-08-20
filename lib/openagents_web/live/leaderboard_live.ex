defmodule OpenAgentsWeb.LeaderboardLive do
  @moduledoc """
  The public leaderboard.

  A read-only projection of `OpenAgents.Leaderboard`. It mounts without a session,
  holds no conversation, and offers no action that can invoke OpenAgents, which is
  what lets a second public surface sit alongside the authentication boundary
  (`INVARIANTS.md` UI-001, LEADERBOARD-001).

  Rows arrive already computed and already bounded. The surface deliberately has
  no query of its own: whatever `OpenAgents.Leaderboard.Entry` does not carry cannot
  be rendered here by accident.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Leaderboard
  alias OpenAgents.Leaderboard.Entry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = Leaderboard.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Leaderboard · OpenAgents")
     |> assign(:entries, Leaderboard.entries())}
  end

  @impl true
  def handle_info({:leaderboard_updated, entries}, socket) do
    {:noreply, assign(socket, :entries, entries)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={assigns[:current_scope]} title="Leaderboard">
      <main id="leaderboard-page" class="app-shell leaderboard-shell">
        <section class="leaderboard" aria-label="Token leaderboard">
          <header class="leaderboard-heading">
            <h1>Leaderboard</h1>
            <p>Accounts ranked by tokens used with OpenAgents, across typed and spoken turns.</p>
          </header>

          <.empty :if={@entries == []} id="leaderboard-empty" title="No tokens yet">
            The board fills in as accounts talk with OpenAgents. It updates live.
          </.empty>

          <ol :if={@entries != []} id="leaderboard-rows" class="leaderboard-rows">
            <li :for={entry <- @entries} id={"leaderboard-rank-#{entry.rank}"}>
              <.card>
                <div class="leaderboard-row">
                  <span class="leaderboard-rank" aria-label={"Rank #{entry.rank}"}>
                    {entry.rank}
                  </span>

                  <.avatar
                    src={entry.github_avatar_url}
                    alt=""
                    size={:sm}
                    fallback={String.first(entry.github_login)}
                  />

                  <span class="leaderboard-identity">
                    <strong :if={Entry.display_name(entry)}>{Entry.display_name(entry)}</strong>
                    <span>@{entry.github_login}</span>
                  </span>

                  <.badge variant={:info} class="leaderboard-total">
                    {format_tokens(entry.total_tokens)} tokens
                  </.badge>
                </div>
              </.card>
            </li>
          </ol>
        </section>
      </main>
    </Layouts.app>
    """
  end

  # Long counts are the point of the board, so they get thousands separators
  # rather than an abbreviation that hides the difference between two accounts.
  defp format_tokens(total) when is_integer(total) do
    total
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
