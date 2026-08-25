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

  ## Email

  This page is also where an account gives an address and confirms it. The
  address is typed here rather than taken from GitHub, and it does nothing
  until a code mailed to it comes back — see
  `OpenAgents.Notifications.EmailChannel`. Only then does the channel switch
  appear, because a switch that turns on a channel with no reachable address
  would be a control that does nothing.

  A deployment with no mail provider says so and offers no address field. That
  is honest rather than defensive: collecting an address it cannot mail to
  would be collecting a secret for no purpose.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Accounts.User
  alias OpenAgents.Notifications
  alias OpenAgents.Notifications.EmailChannel
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

  def handle_event("set_email_address", %{"email" => %{"address" => address}}, socket) do
    socket.assigns.email_account
    |> EmailChannel.set_address(address)
    |> resolve(socket, "Check that address for a verification code.")
  end

  def handle_event("resend_email_code", _params, socket) do
    socket.assigns.email_account
    |> EmailChannel.resend_code()
    |> resolve(socket, "Another code is on its way.")
  end

  def handle_event("verify_email_code", %{"email" => %{"code" => code}}, socket) do
    socket.assigns.email_account
    |> EmailChannel.verify(code)
    |> resolve(socket, "Address confirmed.")
  end

  def handle_event("remove_email_address", _params, socket) do
    socket.assigns.email_account
    |> EmailChannel.remove_address()
    |> resolve(socket, "Address removed. Nothing else will be mailed to it.")
  end

  def handle_event("update_email_channel", %{"channel" => params}, socket) do
    attrs = %{email_enabled: checked?(params["email_enabled"])}

    case Notifications.update_preferences(socket.assigns.current_scope, attrs) do
      {:ok, _preferences} ->
        {:noreply, socket |> put_flash(:info, "Notification settings saved.") |> load()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Notification settings could not be saved.")}
    end
  end

  defp resolve({:ok, %User{} = user}, socket, message) do
    {:noreply,
     socket
     |> assign(:email_account, user)
     |> put_flash(:info, message)
     |> load()}
  end

  defp resolve({:error, reason}, socket, _message) do
    {:noreply, socket |> put_flash(:error, refusal(reason)) |> load()}
  end

  defp refusal(:invalid_address), do: "That does not look like an email address."
  defp refusal(:not_deliverable), do: "This deployment cannot send email."
  defp refusal(:too_soon), do: "A code went out a moment ago. Wait a minute and ask again."
  defp refusal(:nothing_pending), do: "There is no code waiting to be confirmed."
  defp refusal(:expired), do: "That code has expired. Ask for another one."
  defp refusal(:incorrect_code), do: "That code is not right."
  defp refusal(:too_many_attempts), do: "Too many wrong codes. Ask for a new one."
  defp refusal(_reason), do: "That could not be saved."

  defp checked?("true"), do: true
  defp checked?("on"), do: true
  defp checked?(_value), do: false

  defp load(socket) do
    user = socket.assigns.current_scope
    account = Map.get(socket.assigns, :email_account, user)
    notifications = Notifications.list_notifications(user)
    preferences = Notifications.preferences(user)

    socket
    |> assign(:email_account, account)
    |> assign(:email_deliverable?, EmailChannel.deliverable?())
    |> assign(:email_state, EmailChannel.state(account))
    |> assign(
      :email_form,
      to_form(%{"address" => account.notification_email, "code" => ""}, as: :email)
    )
    |> assign(
      :email_channel_form,
      to_form(%{"email_enabled" => preferences.email_enabled}, as: :channel)
    )
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

        <section aria-labelledby="notifications-email-heading" class="flex flex-col gap-4">
          <h2 id="notifications-email-heading" class="text-base font-medium text-foreground">
            Email
          </h2>

          <p
            :if={!@email_deliverable?}
            id="notifications-email-unavailable"
            class="text-sm text-muted-foreground"
          >
            This deployment has no mail provider configured, so there is nowhere to
            send to. Notifications arrive in the inbox above.
          </p>

          <%= if @email_deliverable? do %>
            <p class="text-sm text-muted-foreground">
              Give an address and confirm it with the code that arrives, and mentions
              can also reach you by email. Nothing is sent to an address that has not
              been confirmed, and the channel stays off until you turn it on. Only
              mentions travel this way for now — the other categories are waiting on a
              digest, because one message per comment is not a channel anybody keeps.
            </p>

            <.form
              for={@email_form}
              id="notification-email-address-form"
              phx-submit="set_email_address"
              class="flex flex-col gap-3"
            >
              <.input
                field={@email_form[:address]}
                type="email"
                label="Email address"
                autocomplete="email"
              />

              <div class="flex items-center gap-2">
                <.button id="notification-email-save" type="submit" size={:sm}>
                  {if @email_state.verified?, do: "Change address", else: "Send code"}
                </.button>

                <.button
                  :if={@email_state.address}
                  id="notification-email-remove"
                  variant={:ghost}
                  size={:sm}
                  tone={:danger}
                  phx-click="remove_email_address"
                >
                  Remove
                </.button>
              </div>
            </.form>

            <.form
              :if={@email_state.pending?}
              for={@email_form}
              id="notification-email-code-form"
              phx-submit="verify_email_code"
              class="flex flex-col gap-3"
            >
              <.input
                field={@email_form[:code]}
                type="text"
                label="Verification code"
                autocomplete="one-time-code"
              />

              <div class="flex items-center gap-2">
                <.button id="notification-email-confirm" type="submit" size={:sm}>
                  Confirm
                </.button>

                <.button
                  id="notification-email-resend"
                  variant={:ghost}
                  size={:sm}
                  phx-click="resend_email_code"
                >
                  Send another code
                </.button>
              </div>
            </.form>

            <div :if={@email_state.verified?} class="flex flex-col gap-3">
              <p id="notification-email-verified" class="text-sm text-muted-foreground">
                <.badge variant={:info}>Confirmed</.badge>
                {@email_state.address}
              </p>

              <.form
                for={@email_channel_form}
                id="notification-email-channel-form"
                phx-change="update_email_channel"
              >
                <.input
                  field={@email_channel_form[:email_enabled]}
                  type="checkbox"
                  label="Send mentions to this address"
                />
              </.form>
            </div>
          <% end %>
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
