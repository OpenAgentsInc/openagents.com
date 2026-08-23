defmodule OpenAgentsWeb.IssueShowLive do
  @moduledoc """
  One issue: its description, its history, and the properties you can change.

  Built from `OpenAgentsWeb.UI.Circle`, so the page and the component library
  cannot drift. Every field it shows or edits is one GitHub already has —
  `state`, `state_reason`, `labels`, `assignees`, `milestone`, `locked`, and
  comments. See `docs/2026-08-20-linear-design-github-shape.md`.

  Two structural decisions:

    * **Reading is the default state.** Editing the title and body is behind
      `Edit`, and everything else is edited in place from the rail, so the page
      is a description of the issue rather than a form that happens to be
      showing one.

    * **The history is one feed.** Comments and state changes interleave in a
      single timeline rather than sitting in separate sections, because they
      answer the same question and their order relative to each other is most
      of the answer.

  This schema has no `issue_events` table, so the events are derived from the
  fields it does store: opened from `inserted_at` and `user`, closed from
  `closed_at` and `state_reason`. That is why a close has no actor — nothing
  records who did it, and naming somebody would be a guess.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Comment
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Labels
  alias OpenAgents.Markdown
  alias OpenAgents.Milestones
  alias OpenAgents.Notifications
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.OG
  alias OpenAgentsWeb.UI.Circle

  def mount(%{"owner" => owner, "repo" => repo, "number" => number}, _session, socket) do
    repository =
      try do
        Repositories.get_visible_by_path!(owner, repo, socket.assigns.current_user)
      rescue
        Ecto.NoResultsError ->
          raise OpenAgentsWeb.PublicNotFoundError, message: "repository not found"
      end

    issue = Issues.get_issue_by_number!(repository, String.to_integer(number))

    user = socket.assigns.current_user
    can_write = Repositories.writable?(repository, user)

    if connected?(socket), do: Repositories.subscribe_issues(repository.id)

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:current_user, user)
     |> assign(:can_write, can_write)
     |> assign(
       :can_participate,
       Repositories.issue_participant?(repository, user)
     )
     |> assign(:can_edit, can_write || author?(issue, user))
     |> assign(:editing, false)
     |> assign(:comment_form, to_form(Comment.changeset(%Comment{}, %{})))
     |> assign(:repo_labels, if(can_write, do: Labels.list_labels(repository), else: []))
     |> assign(
       :repo_milestones,
       if(can_write, do: Milestones.list_milestones(repository), else: [])
     )
     |> assign(
       :assignable,
       if(can_write, do: Repositories.list_assignable_users(repository), else: [])
     )
     |> assign(
       :og,
       OG.meta(OG.issue(repository.namespace.slug, repository.name, issue))
     )
     |> load(issue)}
  end

  def handle_event("toggle_subscription", _params, socket) do
    with_authority(socket, :can_participate, "You can no longer follow this issue.", fn socket ->
      issue = socket.assigns.issue
      user = socket.assigns.current_user

      result =
        if socket.assigns.subscribed? do
          Notifications.unsubscribe(issue, user)
        else
          Notifications.subscribe(issue, user, "manual")
        end

      case result do
        {:ok, _subscription} -> {:noreply, load(socket, issue)}
        {:error, _reason} -> {:noreply, put_flash(socket, :error, "That did not work.")}
      end
    end)
  end

  def handle_event("toggle_edit", _params, socket) do
    with_authority(socket, :can_edit, "You can no longer edit this issue.", fn socket ->
      issue = socket.assigns.issue

      {:noreply,
       socket
       |> assign(:editing, !socket.assigns.editing)
       |> assign(:form, to_form(Issues.change_issue(issue)))}
    end)
  end

  def handle_event("save", %{"issue" => issue_params}, socket) do
    with_authority(socket, :can_edit, "You can no longer edit this issue.", fn socket ->
      issue = socket.assigns.issue
      attrs = %{"title" => issue_params["title"], "body" => issue_params["body"]}

      case Issues.update_issue(issue, attrs, socket.assigns.current_user) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:editing, false)
           |> put_flash(:info, "Issue updated")
           |> load(updated)}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    end)
  end

  # A viewer without authority who hand-crafts an event gets a refusal rather
  # than a silent success; the UI never shows them the control in the first
  # place.
  def handle_event("close", _params, socket),
    do: with_edit_authority(socket, &set_state(&1, "closed", "completed"))

  def handle_event("reopen", _params, socket),
    do: with_edit_authority(socket, &set_state(&1, "open", nil))

  # The rail's state menu picks a close reason as well as a state, which the
  # header's two buttons cannot. Both end in the same write.
  def handle_event("set_state", %{"state" => "open"}, socket),
    do: with_edit_authority(socket, &set_state(&1, "open", nil))

  def handle_event("set_state", %{"state" => "closed"} = params, socket),
    do: with_edit_authority(socket, &set_state(&1, "closed", params["reason"] || "completed"))

  def handle_event("toggle_label", %{"name" => name}, socket) do
    with_authority(
      socket,
      :can_write,
      "Only repository members can change issue labels.",
      fn socket ->
        issue = socket.assigns.issue

        {:ok, updated} =
          if Enum.any?(issue.labels || [], &(&1["name"] == name)) do
            Issues.remove_label(issue, name)
          else
            Issues.add_labels(issue, [name])
          end

        {:noreply, load(socket, updated)}
      end
    )
  end

  def handle_event("toggle_assignee", %{"login" => login}, socket) do
    with_authority(
      socket,
      :can_write,
      "Only repository members can change issue assignees.",
      fn socket ->
        issue = socket.assigns.issue

        {:ok, updated} =
          if Enum.any?(issue.assignees || [], &(&1["login"] == login)) do
            Issues.remove_assignees(issue, [login])
          else
            Issues.add_assignees(issue, [login])
          end

        {:noreply, load(socket, updated)}
      end
    )
  end

  def handle_event("set_milestone", %{"number" => number}, socket) do
    with_authority(
      socket,
      :can_write,
      "Only repository members can change issue milestones.",
      fn socket ->
        {:ok, updated} = Issues.set_milestone(socket.assigns.issue, number_or_nil(number))
        {:noreply, load(socket, updated)}
      end
    )
  end

  def handle_event("add_comment", %{"comment" => %{"body" => body}}, socket) do
    with_authority(socket, :can_participate, "Sign in to comment on this issue.", fn socket ->
      issue = socket.assigns.issue

      if issue.locked do
        {:noreply, put_flash(socket, :error, "This conversation is locked.")}
      else
        case Issues.create_comment(issue, %{body: body}, socket.assigns.current_user) do
          {:ok, _comment} ->
            {:noreply,
             socket
             |> assign(:comment_form, to_form(Comment.changeset(%Comment{}, %{})))
             |> put_flash(:info, "Comment added")
             |> load(%{issue | comments: issue.comments + 1})}

          {:error, changeset} ->
            {:noreply, assign(socket, :comment_form, to_form(changeset))}
        end
      end
    end)
  end

  def handle_event(_unsupported_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "That issue action is not available.")}
  end

  # Live updates: someone else's write re-reads this issue through the same
  # visibility check the mount used.
  def handle_info({:issues_changed, repository_id}, socket)
      when repository_id == socket.assigns.repository.id do
    socket = refresh_authority(socket)
    {:noreply, load(socket, socket.assigns.issue)}
  end

  def handle_info({:issues_changed, _other_repository}, socket), do: {:noreply, socket}

  defp author?(%Issue{author_user_id: author_id}, %OpenAgents.Accounts.User{id: user_id})
       when is_binary(author_id),
       do: author_id == user_id

  defp author?(_issue, _user), do: false

  defp set_state(socket, state, reason) do
    attrs = %{"state" => state, "state_reason" => reason}

    {:ok, updated} =
      Issues.update_issue(socket.assigns.issue, attrs, socket.assigns.current_user)

    flash = if state == "closed", do: "Issue closed", else: "Issue reopened"

    {:noreply,
     socket
     |> put_flash(:info, flash)
     |> load(updated)}
  end

  defp with_edit_authority(socket, operation) do
    with_authority(socket, :can_edit, "You can no longer change this issue's state.", operation)
  end

  defp with_authority(socket, permission, message, operation) do
    socket = refresh_authority(socket)

    if socket.assigns[permission] do
      operation.(socket)
    else
      {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp refresh_authority(socket) do
    user = socket.assigns.current_user

    visible_repository = Repositories.get_visible_repository(socket.assigns.repository.id, user)
    repository = visible_repository || socket.assigns.repository
    visible? = not is_nil(visible_repository)
    can_write = visible? and Repositories.writable?(repository, user)
    can_participate = visible? and Repositories.issue_participant?(repository, user)
    issue = Issues.get_issue!(socket.assigns.repository, socket.assigns.issue.id)
    can_edit = can_write || (can_participate and author?(issue, user))

    socket
    |> assign(:repository, repository)
    |> assign(:issue, issue)
    |> assign(:can_write, can_write)
    |> assign(:can_participate, can_participate)
    |> assign(:can_edit, can_edit)
    |> assign(:editing, socket.assigns.editing and can_edit)
  end

  # One place rebuilds everything derived from the issue, so a write cannot
  # leave the timeline describing the previous version of the page.
  defp load(socket, issue) do
    comments = Issues.list_comments(issue)

    socket
    |> assign(:issue, issue)
    |> assign(:comments, comments)
    |> assign(:form, to_form(Issues.change_issue(issue)))
    |> assign(:events, timeline(issue, comments))
    |> assign(:subscribed?, subscribed?(issue, socket.assigns.current_user))
  end

  defp subscribed?(_issue, nil), do: false
  defp subscribed?(issue, user), do: Notifications.subscribed?(issue, user)

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      wide
    >
      <Circle.issue_detail>
        <:heading>
          <.form
            :if={@editing}
            for={@form}
            id="issue-edit-form"
            phx-submit="save"
            class="issue-editor"
          >
            <.input field={@form[:title]} label="Title" />
            <.input field={@form[:body]} type="textarea" label="Body" />
            <footer class="issue-editor__foot">
              <button type="button" class="btn" data-variant="ghost" phx-click="toggle_edit">
                Cancel
              </button>
              <.button type="submit" variant={:primary}>Save</.button>
            </footer>
          </.form>

          <div :if={!@editing} class="issue-heading">
            <h1 class="issue-heading__title">
              {@issue.title}
              <span class="issue-heading__number">#{@issue.number}</span>
            </h1>
            <p class="issue-heading__meta">
              <Circle.issue_state state={@issue.state} reason={@issue.state_reason} show_label />
              <span class="issue-heading__dot" aria-hidden="true">·</span>
              <span>
                {author(@issue)} opened this {relative(@issue.inserted_at)} ago
              </span>
              <span :if={@issue.comments > 0} class="issue-heading__dot" aria-hidden="true">·</span>
              <span :if={@issue.comments > 0}>
                {@issue.comments} {ngettext_comments(@issue.comments)}
              </span>
            </p>
            <div class="issue-heading__actions">
              <button
                :if={@can_edit and @issue.state == "open"}
                class="btn"
                data-variant="primary"
                data-size="sm"
                phx-click="close"
              >
                Close issue
              </button>
              <button
                :if={@can_edit and @issue.state == "closed"}
                class="btn"
                data-variant="ghost"
                data-size="sm"
                phx-click="reopen"
              >
                Reopen issue
              </button>
              <button
                :if={@can_edit}
                class="btn"
                data-variant="ghost"
                data-size="sm"
                phx-click="toggle_edit"
              >
                <.icon name="edit" /> Edit
              </button>
            </div>
          </div>
        </:heading>

        <:rail>
          <Circle.properties_panel :if={@can_write}>
            <:group heading="State">
              <Circle.field_menu id="issue-state-menu" label="Change the state of this issue">
                <:trigger>
                  <Circle.issue_state
                    state={@issue.state}
                    reason={@issue.state_reason}
                    show_label
                  />
                </:trigger>
                <Circle.field_menu_item
                  :for={{label, state, reason} <- state_options()}
                  label={label}
                  mode={:choice}
                  selected={@issue.state == state and close_reason(@issue) == reason}
                  closes="issue-state-menu"
                  on_select={JS.push("set_state", value: %{state: state, reason: reason})}
                >
                  <:glyph><Circle.issue_state state={state} reason={reason} /></:glyph>
                </Circle.field_menu_item>
              </Circle.field_menu>
            </:group>

            <:group heading="Assignees">
              <Circle.assignee
                :for={assignee <- @issue.assignees}
                name={assignee["login"]}
                show_name
                size={:sm}
              />
              <span :if={@issue.assignees == []} class="properties-panel__none">No one assigned</span>
              <Circle.field_menu id="issue-assignee-menu" label="Assign this issue" align={:end}>
                <:trigger><.icon name="user-add" class="properties-panel__add" /></:trigger>
                <Circle.field_menu_item
                  :for={user <- @assignable}
                  label={user.github_login}
                  selected={assigned?(@issue, user.github_login)}
                  on_select={JS.push("toggle_assignee", value: %{login: user.github_login})}
                >
                  <:glyph><Circle.assignee name={user.github_login} size={:sm} /></:glyph>
                </Circle.field_menu_item>
                <p :if={@assignable == []} class="properties-panel__none">
                  Nobody in this repository can be assigned yet.
                </p>
              </Circle.field_menu>
            </:group>

            <:group heading="Labels">
              <Circle.issue_label
                :for={label <- @issue.labels}
                name={label["name"]}
                tone={label_tone(label["color"])}
              />
              <span :if={@issue.labels == []} class="properties-panel__none">None yet</span>
              <Circle.field_menu
                id="issue-label-menu"
                label="Change the labels on this issue"
                align={:end}
              >
                <:trigger><.icon name="tag" class="properties-panel__add" /></:trigger>
                <Circle.field_menu_item
                  :for={label <- @repo_labels}
                  label={label.name}
                  selected={labelled?(@issue, label.name)}
                  on_select={JS.push("toggle_label", value: %{name: label.name})}
                >
                  <:glyph>
                    <span class="issue-label__dot" data-tone={label_tone(label.color)} />
                  </:glyph>
                </Circle.field_menu_item>
                <p :if={@repo_labels == []} class="properties-panel__none">
                  This repository has no labels yet.
                </p>
              </Circle.field_menu>
            </:group>

            <:group heading="Milestone">
              <.link
                :if={@issue.milestone}
                navigate={~p"/#{@owner}/#{@repo}/milestones"}
                class="properties-panel__link"
              >
                <.icon name="flag" /> {@issue.milestone["title"]}
              </.link>
              <span :if={!@issue.milestone} class="properties-panel__none">No milestone</span>
              <Circle.field_menu id="issue-milestone-menu" label="Set the milestone" align={:end}>
                <:trigger><.icon name="edit-pencil" class="properties-panel__add" /></:trigger>
                <Circle.field_menu_item
                  label="No milestone"
                  mode={:choice}
                  selected={is_nil(@issue.milestone)}
                  closes="issue-milestone-menu"
                  on_select={JS.push("set_milestone", value: %{number: ""})}
                />
                <Circle.field_menu_item
                  :for={milestone <- @repo_milestones}
                  label={milestone.title}
                  icon="flag"
                  mode={:choice}
                  selected={milestoned?(@issue, milestone.number)}
                  closes="issue-milestone-menu"
                  on_select={JS.push("set_milestone", value: %{number: milestone.number})}
                />
              </Circle.field_menu>
            </:group>
          </Circle.properties_panel>

          <%!-- Outside the properties panel on purpose. Everything in that
          panel changes the issue and needs a writable membership; following an
          issue changes only what reaches your own inbox, so it is offered to
          anyone who may take part in the conversation. --%>
          <section :if={@can_participate} class="properties-panel__group">
            <h3 class="properties-panel__heading">Notifications</h3>
            <p class="properties-panel__none">
              {if @subscribed?,
                do: "You get comments on this issue.",
                else: "You do not get comments on this issue."}
            </p>
            <.button
              id="issue-subscription-toggle"
              variant={:ghost}
              size={:sm}
              phx-click="toggle_subscription"
            >
              {if @subscribed?, do: "Unsubscribe", else: "Subscribe"}
            </.button>
          </section>
        </:rail>

        <section class="issue-body">
          <div :if={@issue.body} class="timeline-comment__body !p-0">
            {Markdown.to_html(@issue.body)}
          </div>
          <p :if={!@issue.body} class="properties-panel__none">No description provided.</p>
        </section>

        <Circle.timeline>
          <%= for event <- @events do %>
            <Circle.timeline_comment
              :if={event.kind == :comment}
              id={"comment-#{event.id}"}
              author={event.actor}
              at={event.at}
              badge={event.badge}
            >
              {Markdown.to_html(event.body)}
            </Circle.timeline_comment>
            <Circle.timeline_event
              :if={event.kind == :event}
              actor={event.actor}
              text={event.text}
              icon={event.icon}
              tone={event.tone}
              at={event.at}
            />
          <% end %>
        </Circle.timeline>

        <.alert :if={@issue.locked} variant={:warning} appearance={:notice}>
          This conversation is locked{if @issue.locked_reason, do: " as #{@issue.locked_reason}"}.
        </.alert>

        <.alert
          :if={!@can_participate and !@issue.locked}
          variant={:info}
          appearance={:notice}
          id="sign-in-to-comment"
        >
          <.link navigate={~p"/"} class="font-medium underline">
            Sign in with GitHub
          </.link>
          to comment on this issue.
        </.alert>

        <.form
          :if={@can_participate and !@issue.locked}
          for={@comment_form}
          id="comment-form"
          phx-submit="add_comment"
        >
          <Circle.comment_composer id="issue-composer" author={viewer(@current_user)}>
            <.input
              field={@comment_form[:body]}
              type="textarea"
              label="Comment"
              placeholder="Leave a comment"
            />
            <:hint>Markdown is supported.</:hint>
            <:actions>
              <.button type="submit" variant={:primary} size={:sm}>Comment</.button>
            </:actions>
          </Circle.comment_composer>
        </.form>
      </Circle.issue_detail>
    </Layouts.app>
    """
  end

  # ── the derived history ────────────────────────────────────────────────────

  # GitHub's timeline is an endpoint backed by an event log. This schema has no
  # such table, so the feed is assembled from the columns that do exist. The
  # result is honest but partial: a label added and removed leaves no trace,
  # and a close records when but not who.
  defp timeline(issue, comments) do
    opened = %{
      kind: :event,
      actor: author(issue),
      text: "opened this issue",
      icon: "plus-circle",
      tone: :neutral,
      at: stamp(issue.inserted_at),
      sort: issue.inserted_at
    }

    commented =
      Enum.map(comments, fn comment ->
        login = actor_label(comment.user)

        %{
          kind: :comment,
          id: comment.id,
          actor: login,
          badge: if(login == author(issue), do: "Author"),
          body: comment.body,
          at: stamp(comment.created_at),
          sort: comment.created_at
        }
      end)

    closed =
      if issue.state == "closed" and issue.closed_at do
        [
          %{
            kind: :event,
            actor: nil,
            text: close_text(issue),
            icon: close_icon(issue),
            tone: close_tone(issue),
            at: stamp(issue.closed_at),
            sort: issue.closed_at
          }
        ]
      else
        []
      end

    Enum.sort_by([opened | commented] ++ closed, & &1.sort, DateTime)
  end

  defp close_text(%{state_reason: "not_planned"}), do: "closed this as not planned"
  defp close_text(%{state_reason: "duplicate"}), do: "closed this as a duplicate"
  defp close_text(_issue), do: "closed this as completed"

  defp close_icon(%{state_reason: reason}) when reason in ["not_planned", "duplicate"],
    do: "x-circle-filled"

  defp close_icon(_issue), do: "octicon-issue-closed"

  defp close_tone(%{state_reason: reason}) when reason in ["not_planned", "duplicate"],
    do: :danger

  defp close_tone(_issue), do: :success

  # ── GitHub's fields, read the way this interface reads them ────────────────

  # The three states this application can express. `duplicate` is a valid
  # GitHub close reason and is rendered when it arrives from the API, but it is
  # not offered here: the menu that sets it has nowhere to record which issue
  # it duplicates, and a duplicate that does not say of what is worse than a
  # plain close.
  defp state_options do
    [
      {"Open", "open", nil},
      {"Closed as completed", "closed", "completed"},
      {"Closed as not planned", "closed", "not_planned"}
    ]
  end

  defp close_reason(%{state: "closed", state_reason: reason}), do: reason || "completed"
  defp close_reason(_issue), do: nil

  # `JS.push` sends a number as a number and a form sends it as a string, so
  # the handler takes whichever arrives rather than making the call sites agree.
  defp number_or_nil(""), do: nil
  defp number_or_nil(number) when is_integer(number), do: number
  defp number_or_nil(number) when is_binary(number), do: String.to_integer(number)

  defp assigned?(issue, login), do: Enum.any?(issue.assignees || [], &(&1["login"] == login))
  defp labelled?(issue, name), do: Enum.any?(issue.labels || [], &(&1["name"] == name))
  defp milestoned?(%{milestone: %{"number" => n}}, number), do: n == number
  defp milestoned?(_issue, _number), do: false

  defp author(issue), do: actor_label(issue.user)

  defp login(%{} = user), do: user["login"] || user[:login] || "anonymous"
  defp login(_user), do: "anonymous"

  defp actor_label(%{"agent" => true} = user), do: "#{login(user)} (agent)"
  defp actor_label(user), do: login(user)

  defp viewer(%{github_login: login}) when is_binary(login), do: login
  defp viewer(_user), do: nil

  defp ngettext_comments(1), do: "comment"
  defp ngettext_comments(_count), do: "comments"

  # A GitHub label carries a hex colour chosen by whoever made it. Rendering it
  # would put a second palette on the page, and dropping it would make every
  # label grey. So the hue is read and mapped to the nearest tone on our
  # ladder: the author's intent survives -- red means broken, green means new
  # -- while the values stay ours.
  defp label_tone(color) when is_binary(color) do
    case Integer.parse(String.trim_leading(color, "#"), 16) do
      {value, _rest} -> hue_tone(value)
      :error -> :neutral
    end
  end

  defp label_tone(_color), do: :neutral

  defp hue_tone(value) do
    r = div(value, 65_536)
    g = value |> div(256) |> rem(256)
    b = rem(value, 256)
    high = Enum.max([r, g, b])
    low = Enum.min([r, g, b])

    # A grey label is as deliberate a choice as a red one, so anything close to
    # the diagonal stays neutral rather than being forced into a hue.
    if high == 0 or (high - low) / high < 0.2 do
      :neutral
    else
      r |> hue(g, b, high, low) |> tone_for_hue()
    end
  end

  defp hue(r, g, b, high, low) do
    delta = high - low

    sextant =
      cond do
        high == r -> wrap((g - b) / delta)
        high == g -> (b - r) / delta + 2
        true -> (r - g) / delta + 4
      end

    sextant * 60
  end

  # The red sextant straddles zero: a value of -0.5 is 330 degrees, not -30.
  defp wrap(sextant) when sextant < 0, do: sextant + 6
  defp wrap(sextant), do: sextant

  defp tone_for_hue(h) when h < 20 or h >= 340, do: :danger
  defp tone_for_hue(h) when h < 70, do: :warning
  defp tone_for_hue(h) when h < 170, do: :success
  defp tone_for_hue(h) when h < 260, do: :info
  defp tone_for_hue(_h), do: :primary

  defp stamp(nil), do: nil
  defp stamp(at), do: "#{relative(at)} ago"

  defp relative(nil), do: nil

  defp relative(at) do
    at = if is_struct(at, NaiveDateTime), do: DateTime.from_naive!(at, "Etc/UTC"), else: at

    case DateTime.diff(DateTime.utc_now(), at, :second) do
      s when s < 3_600 -> "#{max(div(s, 60), 1)}m"
      s when s < 86_400 -> "#{div(s, 3_600)}h"
      s -> "#{div(s, 86_400)}d"
    end
  end
end
