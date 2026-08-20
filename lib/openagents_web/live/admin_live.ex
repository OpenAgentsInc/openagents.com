defmodule OpenAgentsWeb.AdminLive do
  @moduledoc """
  The operator surface: every account, newest first, with what each has done here.

  Read-only by construction. `OpenAgents.Admin` exposes no write, so nothing
  here can ban an account, alter a conversation, or change configuration
  (`INVARIANTS.md` ADMIN-001). The only action is paging.

  This lists accounts and activity counts, never content. Knowing that someone
  sent forty messages is an operational fact; reading them is a different
  decision with a different implementation, and there is no route to it from
  here.

  It replaced a voice-call recordings panel. Recording was off, the product no
  longer captures call audio, and an operator surface whose only view is of a
  capability that does not run is worse than no surface: it describes the
  system inaccurately to the one person who most needs an accurate picture.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Accounts
  alias OpenAgents.Admin

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      {:ok,
       socket
       |> assign(:page_title, "Operator · OpenAgents")
       |> assign(:offset, 0)
       |> load_page()}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event(event, _params, socket) when event in ["next_page", "previous_page"] do
    # Re-checked per event, not only at mount: a long-lived socket outlives the
    # decision that opened it.
    if Accounts.admin?(socket.assigns.current_user) do
      do_handle_event(event, socket)
    else
      {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  defp do_handle_event("next_page", socket) do
    offset = socket.assigns.offset + @page_size

    if offset < socket.assigns.total,
      do: {:noreply, socket |> assign(:offset, offset) |> load_page()},
      else: {:noreply, socket}
  end

  defp do_handle_event("previous_page", socket) do
    offset = max(socket.assigns.offset - @page_size, 0)
    {:noreply, socket |> assign(:offset, offset) |> load_page()}
  end

  defp load_page(socket) do
    socket
    |> assign(:total, Admin.count_accounts())
    |> assign(:accounts, Admin.list_accounts(limit: @page_size, offset: socket.assigns.offset))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} title="Admin" wide>
      <section class="panel" aria-label="Accounts">
        <header class="panel__header">
          <h1 class="panel__title">Accounts</h1>
          <span class="admin-count">{@total} total</span>
        </header>

        <.empty :if={@accounts == []} id="admin-empty" title="No accounts yet">
          Accounts appear here after their first sign-in.
        </.empty>

        <div :if={@accounts != []} class="admin-table-scroll">
          <table id="admin-accounts" class="admin-table">
            <thead>
              <tr>
                <th scope="col">Account</th>
                <th scope="col">Joined</th>
                <th scope="col">Last seen</th>
                <th scope="col" class="admin-table__number">Messages</th>
                <th scope="col" class="admin-table__number">Issues</th>
                <th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={account <- @accounts} id={"admin-account-#{account.id}"}>
                <td>
                  <div class="admin-identity">
                    <.avatar
                      src={account.github_avatar_url}
                      alt=""
                      size={:sm}
                      fallback={String.first(account.github_login)}
                    />
                    <span class="admin-identity__names">
                      <strong :if={account.github_name}>{account.github_name}</strong>
                      <span>@{account.github_login}</span>
                    </span>
                  </div>
                </td>
                <td>{date(account.joined_at)}</td>
                <td>{date(account.last_authenticated_at)}</td>
                <td class="admin-table__number">{account.message_count}</td>
                <td class="admin-table__number">{account.issue_count}</td>
                <td>
                  <.badge variant={status_variant(account.status)}>
                    {String.upcase(account.status)}
                  </.badge>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <footer :if={@total > page_size()} class="admin-paging">
          <.button
            id="previous-page"
            variant={:secondary}
            size={:sm}
            phx-click="previous_page"
            disabled={@offset == 0}
          >
            Previous
          </.button>
          <span class="admin-paging__position">
            {@offset + 1}–{min(@offset + page_size(), @total)} of {@total}
          </span>
          <.button
            id="next-page"
            variant={:secondary}
            size={:sm}
            phx-click="next_page"
            disabled={@offset + page_size() >= @total}
          >
            Next
          </.button>
        </footer>
      </section>
    </Layouts.app>
    """
  end

  # `@page_size` inside ~H would be an assign lookup, not this attribute.
  defp page_size, do: @page_size

  # A date, not a timestamp. An operator scanning a list wants to know roughly
  # when, and to-the-second precision in a column invites arithmetic nobody
  # asked for.
  defp date(nil), do: "—"
  defp date(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.to_iso8601()

  defp date(%NaiveDateTime{} = at),
    do: at |> NaiveDateTime.to_date() |> Date.to_iso8601()

  defp status_variant("active"), do: :success
  defp status_variant("banned"), do: :danger
  defp status_variant(_status), do: :default
end
