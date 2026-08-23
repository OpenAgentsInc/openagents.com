defmodule OpenAgentsWeb.NotificationsLive do
  @moduledoc """
  What happened on the issues you follow.

  ## What reaches this page

  Somebody named you with `@your-login` in an issue or a comment, somebody
  commented on an issue you follow, somebody closed or reopened one, somebody
  labelled one, or somebody assigned one to you. You follow an issue by opening
  it, commenting on it, being named in it, being assigned it, or pressing
  **Subscribe** on it, and you stop by pressing **Unsubscribe** — which sticks,
  so commenting again does not quietly resubscribe you.

  Assignment is the exception to following: it reaches you whether or not you
  followed the issue, because it is addressed to you by name.

  ## Authorization

  Every row is re-read through `OpenAgents.Repositories.readable_by/2` on this
  request, not on the request that wrote it. A notification about a private
  repository disappears from the inbox the moment the reader's membership ends,
  and it never carried the issue's title or body to begin with — the record
  stores identifiers and an actor's login, and this page reads the issue
  itself only after the predicate admits the row.

  ## Bound

  One page is `OpenAgents.Notifications.per_page/0` rows. There is no older
  page yet; the inbox is a recent-activity surface, and an archive is a
  separate question from delivery.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Notifications
  alias OpenAgents.Notifications.Preference
  alias OpenAgents.Repositories

  def mount(_params, _session, socket) do
    if connected?(socket), do: Repositories.subscribe_all_issues()

    {:ok, load(socket)}
  end

  # The same message the issue lists already listen to. It carries a repository
  # id and nothing else, so this view re-reads through its own predicate rather
  # than trusting a payload.
  def handle_info({:issues_changed, _repository_id}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  def handle_event("mark_read", %{"id" => id}, socket) do
    {:ok, _count} = Notifications.mark_read(socket.assigns.current_scope, id)
    {:noreply, load(socket)}
  end

  def handle_event("mark_all_read", _params, socket) do
    {:ok, _count} = Notifications.mark_all_read(socket.assigns.current_scope)
    {:noreply, load(socket)}
  end

  def handle_event("update_preferences", %{"preferences" => params}, socket) do
    attrs = Map.new(Preference.categories(), &{&1, checked?(params[Atom.to_string(&1)])})

    case Notifications.update_preferences(socket.assigns.current_scope, attrs) do
      {:ok, _preferences} ->
        {:noreply, socket |> put_flash(:info, "Notification settings saved.") |> load()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Notification settings could not be saved.")}
    end
  end

  defp checked?("true"), do: true
  defp checked?("on"), do: true
  defp checked?(_value), do: false

  defp load(socket) do
    user = socket.assigns.current_scope
    notifications = Notifications.list_notifications(user)
    preferences = Notifications.preferences(user)

    socket
    |> assign(:unread_count, Notifications.unread_count(user))
    |> assign(:notifications_empty?, notifications == [])
    |> assign(
      :preferences_form,
      to_form(
        Map.new(Preference.categories(), fn category ->
          {Atom.to_string(category), Map.fetch!(Map.from_struct(preferences), category)}
        end),
        as: :preferences
      )
    )
    |> stream(:notifications, notifications, reset: true)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Notifications"
      subtitle="Mentions and comments on issues you follow"
    >
      <div class="flex flex-col gap-8 max-w-3xl">
        <section aria-labelledby="notifications-inbox-heading" class="flex flex-col gap-4">
          <div class="flex items-baseline justify-between gap-4">
            <h2 id="notifications-inbox-heading" class="text-base font-medium text-foreground">
              Inbox
              <.badge :if={@unread_count > 0} variant={:info} id="notifications-unread-count">
                {@unread_count} unread
              </.badge>
            </h2>

            <.button
              :if={@unread_count > 0}
              id="notifications-mark-all-read"
              variant={:ghost}
              size={:sm}
              phx-click="mark_all_read"
            >
              Mark all read
            </.button>
          </div>

          <.empty
            :if={@notifications_empty?}
            id="notifications-empty"
            title="Nothing yet"
          >
            When somebody mentions you with an at-sign, or comments on an issue you
            follow, it lands here. Open an issue and press Subscribe to start
            following one.
          </.empty>

          <ul id="notifications-list" phx-update="stream" class="flex flex-col gap-2">
            <li
              :for={{dom_id, notification} <- @streams.notifications}
              id={dom_id}
              class="rounded-md border border-border bg-card p-4 flex flex-col gap-2"
              data-read={!is_nil(notification.read_at)}
            >
              <div class="flex items-start justify-between gap-4">
                <div class="flex flex-col gap-1 min-w-0">
                  <p class="text-sm text-muted-foreground">
                    <.badge variant={kind_variant(notification.kind)}>
                      {kind_label(notification.kind)}
                    </.badge>
                    <span :if={notification.actor_login}>
                      {notification.actor_login}
                    </span>
                  </p>

                  <.link
                    navigate={
                      ~p"/#{notification.repository.owner}/#{notification.repository.name}/issues/#{notification.issue.number}"
                    }
                    class="text-sm font-medium text-foreground hover:underline truncate"
                  >
                    {notification.issue.title}
                  </.link>

                  <p class="text-xs text-muted-foreground">
                    {notification.repository.owner}/{notification.repository.name} #{notification.issue.number}
                  </p>
                </div>

                <.button
                  :if={is_nil(notification.read_at)}
                  id={"mark-read-#{notification.id}"}
                  variant={:ghost}
                  size={:sm}
                  phx-click="mark_read"
                  phx-value-id={notification.id}
                >
                  Mark read
                </.button>
              </div>
            </li>
          </ul>
        </section>

        <section aria-labelledby="notifications-settings-heading" class="flex flex-col gap-4">
          <h2 id="notifications-settings-heading" class="text-base font-medium text-foreground">
            Settings
          </h2>

          <p class="text-sm text-muted-foreground">
            Every category except label changes starts on. None of them can reach a
            stranger: comments and activity reach you only on issues you already
            took part in, a mention needs somebody to name you, and an assignment
            names you. Label changes start off because a label moves for a query
            rather than for a reader.
          </p>

          <.form
            for={@preferences_form}
            id="notification-preferences-form"
            phx-change="update_preferences"
            class="flex flex-col gap-3"
          >
            <.input
              field={@preferences_form[:mentions_enabled]}
              type="checkbox"
              label="Mentions"
            />
            <.input
              field={@preferences_form[:issue_comments_enabled]}
              type="checkbox"
              label="Comments on issues you follow"
            />
            <.input
              field={@preferences_form[:assignments_enabled]}
              type="checkbox"
              label="Issues assigned to you"
            />
            <.input
              field={@preferences_form[:issue_activity_enabled]}
              type="checkbox"
              label="Closed and reopened on issues you follow"
            />
            <.input
              field={@preferences_form[:label_changes_enabled]}
              type="checkbox"
              label="Label changes on issues you follow"
            />
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp kind_label("mention"), do: "Mentioned you"
  defp kind_label("issue_comment"), do: "New comment"
  defp kind_label("assigned"), do: "Assigned to you"
  defp kind_label("unassigned"), do: "Unassigned from you"
  defp kind_label("labeled"), do: "Label added"
  defp kind_label("unlabeled"), do: "Label removed"
  defp kind_label("state_changed"), do: "State changed"
  defp kind_label(_kind), do: "Activity"

  # The two kinds addressed to one person by name carry the accent; the rest
  # are activity on a thread and read as metadata.
  defp kind_variant("mention"), do: :info
  defp kind_variant("assigned"), do: :info
  defp kind_variant(_kind), do: :dim
end
