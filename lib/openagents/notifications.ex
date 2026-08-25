defmodule OpenAgents.Notifications do
  @moduledoc """
  Subscriptions, mentions, and in-product delivery for issue activity.

  Three rules govern everything here.

  **Delivery is durable, not fire-and-forget.** Fan-out runs inside the
  transaction that writes the comment or the issue, so a delivery record exists
  exactly when the event it announces exists. There is no queue to drain and no
  window where the comment committed but the notification did not.

  **Delivery is idempotent.** Every event produces one `dedupe_key` per
  recipient, and a unique index over `(user_id, dedupe_key)` turns a repeated
  fan-out into a no-op. Retrying a failed request cannot notify twice.

  **A notification never reveals what the recipient cannot read.** The row
  stores identifiers and an actor login, never a title or a body. Fan-out
  refuses a recipient who cannot read the repository, and every read composes
  `OpenAgents.Repositories.readable_by/2` again, so a recipient who loses
  membership after the row was written stops seeing it.

  ## The second channel

  Delivery is in-product first and by email second. The inbox is the channel
  with no switch, because it is the product surface; email is off until an
  account confirms an address (`OpenAgents.Notifications.EmailChannel`) and
  turns `email_enabled` on, and it carries mentions only. A mention is the
  event addressed to one person by name and the lowest-volume category there
  is; the rest wait for a digest, because one message per comment on a busy
  issue is how a channel gets filtered to a folder nobody opens (#141).

  Email cannot inherit the durability the inbox gets for free. The record is
  written in the transaction, but the send is not, so `Delivery.enqueue/1`
  writes an `email.delivery` effect in that same transaction and
  `OpenAgents.Effects` owns the attempts. `email_dispatch/1` is the other half:
  it re-decides, at send time, everything the enqueue decided — confirmed
  address, channel, category, and the recipient's access to the repository — so
  a queued message cannot outlive the consent it was queued under.
  """

  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Issues.Comment
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Notifications.Delivery
  alias OpenAgents.Notifications.EmailChannel
  alias OpenAgents.Notifications.IssueSubscription
  alias OpenAgents.Notifications.Mentions
  alias OpenAgents.Notifications.Notification
  alias OpenAgents.Notifications.Preference
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  # One event cannot address an unbounded audience. A body naming more accounts
  # than this notifies the first `@mention_limit` and drops the rest, so a
  # pasted list cannot turn one comment into thousands of rows.
  @mention_limit 50

  @notifications_per_page 50

  # The kinds the email channel carries. One, deliberately. A mention names a
  # person, so it is the category whose volume is bounded by how often somebody
  # types your login; every other kind follows the traffic on a thread, and
  # mailing one message per comment is what a digest exists to avoid (#141).
  @email_kinds ["mention"]

  def per_page, do: @notifications_per_page

  ## Announcements

  @doc """
  Watches one account's unread count.

  The same shape every other live surface here uses: a topic per subject, a
  message carrying an identifier and nothing else, and a subscriber that
  re-reads through its own authorization. A per-account topic rather than the
  repository-wide `issues:all` the inbox listens to, because the count has to
  move on two events that topic never carries — marking one record read, and
  marking them all read — and because a count that recomputed on every issue
  write anywhere would ask one aggregate per open session per write.
  """
  def subscribe_unread(%User{id: user_id}),
    do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, unread_topic(user_id))

  def subscribe_unread(nil), do: :ok

  @doc """
  Tells the named accounts their unread count moved.

  Called after the owning transaction commits, never inside it. A subscriber
  that re-read too early would count the rows as they were before the write and
  then never hear again, so the badge would sit one event behind until the next
  navigation.
  """
  def broadcast_unread(user_ids) when is_list(user_ids) do
    user_ids
    |> Enum.uniq()
    |> Enum.each(fn user_id ->
      Phoenix.PubSub.broadcast(
        OpenAgents.PubSub,
        unread_topic(user_id),
        {:unread_notifications_changed, user_id}
      )
    end)
  end

  def broadcast_unread(%User{id: user_id}), do: broadcast_unread([user_id])
  def broadcast_unread(user_id) when is_binary(user_id), do: broadcast_unread([user_id])

  defp unread_topic(user_id), do: "notifications:" <> user_id

  ## Subscriptions

  @doc """
  Records that `user` follows `issue`, unless they already muted it.

  An automatic reason — authoring, commenting, being mentioned — never
  overrides an explicit mute, because taking part again is not a decision to
  start hearing about it again. `:manual` is the one reason that does, since it
  is the person themselves asking.
  """
  def subscribe(issue, user, reason)

  def subscribe(%Issue{} = issue, %User{} = user, reason)
      when reason in ~w(author commented mentioned assigned manual) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    replace =
      if reason == "manual" do
        [subscribed: true, reason: "manual", updated_at: now]
      else
        [updated_at: now]
      end

    %IssueSubscription{}
    |> IssueSubscription.changeset(%{reason: reason, subscribed: true})
    |> Ecto.Changeset.put_change(:issue_id, issue.id)
    |> Ecto.Changeset.put_change(:repository_id, issue.repository_id)
    |> Ecto.Changeset.put_change(:user_id, user.id)
    |> Repo.insert(
      on_conflict: [set: replace],
      conflict_target: [:issue_id, :user_id]
    )
  end

  def subscribe(_issue, _user, _reason), do: {:error, :invalid_subscriber}

  @doc "Mutes `issue` for `user`. The row stays so participating again cannot undo it."
  def unsubscribe(%Issue{} = issue, %User{} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %IssueSubscription{}
    |> IssueSubscription.changeset(%{reason: "manual", subscribed: false})
    |> Ecto.Changeset.put_change(:issue_id, issue.id)
    |> Ecto.Changeset.put_change(:repository_id, issue.repository_id)
    |> Ecto.Changeset.put_change(:user_id, user.id)
    |> Repo.insert(
      on_conflict: [set: [subscribed: false, reason: "manual", updated_at: now]],
      conflict_target: [:issue_id, :user_id]
    )
  end

  def unsubscribe(_issue, _user), do: {:error, :invalid_subscriber}

  @doc "The subscription row for this pair, or `nil`."
  def subscription(%Issue{} = issue, %User{} = user) do
    Repo.one(
      from subscription in IssueSubscription,
        where: subscription.issue_id == ^issue.id and subscription.user_id == ^user.id
    )
  end

  def subscription(_issue, _user), do: nil

  @doc "Whether `user` currently follows `issue`."
  def subscribed?(issue, user) do
    case subscription(issue, user) do
      %IssueSubscription{subscribed: subscribed} -> subscribed
      nil -> false
    end
  end

  ## Fan-out

  @doc """
  Announces a new issue.

  The author starts following their own issue, and every account named in the
  body hears about it once.

  Returns the ids of the accounts that got a record, so the caller can announce
  their new counts once the transaction has committed.
  """
  def issue_opened(%Issue{} = issue, author) do
    subscribe_author(issue, author, "author")
    deliver(issue, nil, author, "issue:#{issue.id}:opened", issue.body)
  end

  @doc """
  Announces a new comment.

  The commenter starts following the issue, accounts named in the comment hear
  about it as a mention, and everyone already following hears about it as issue
  activity. A recipient named in a comment they already follow gets one record,
  not two: the mention wins, because being addressed by name is the stronger
  claim on attention.

  Returns the ids of the accounts that got a record.
  """
  def comment_created(%Issue{} = issue, %Comment{} = comment, author) do
    subscribe_author(issue, author, "commented")
    deliver(issue, comment, author, "comment:#{comment.id}", comment.body)
  end

  @doc """
  Announces what changed about an issue.

  The event kinds are derived from the difference between the issue before and
  the issue after, inside the transaction that wrote it. There is no
  `issue_events` table to read from, and `update_issue/3` is the one chokepoint
  every state change, label edit and assignment passes through, so the
  difference is the only honest source of a typed event today. Deriving it here
  keeps that chokepoint single: no caller writes a second update path to
  announce what it did.

  A change to the title, the body, the milestone or the lock announces nothing.
  Those are edits to a document, not events in a thread, and an inbox that
  reported every typo correction would stop being read.

  Assignment addresses one person, so it reaches the assignee whether or not
  they followed the issue, and starts them following it. Everything else
  reaches the people already following.

  Returns the ids of the accounts that got a record.
  """
  def issue_updated(%Issue{} = before, %Issue{} = updated, actor) do
    case derive_events(before, updated) do
      [] ->
        []

      events ->
        repository = Repo.get(Repository, updated.repository_id)
        Enum.flat_map(events, &deliver_event(updated, repository, actor, &1))
    end
  end

  # An event is a kind, the fragment that identifies this transition, and who
  # it addresses. The fragment names the field and its new value rather than a
  # row id, because the transition has no row of its own.
  defp derive_events(before, updated) do
    state_events(before, updated) ++
      assignee_events(before, updated) ++ label_events(before, updated)
  end

  defp state_events(%Issue{state: state}, %Issue{state: state}), do: []

  defp state_events(_before, %Issue{state: state}),
    do: [{"state_changed", "state:#{state}", :subscribers}]

  defp assignee_events(before, updated) do
    was = assignee_logins(before)
    now = assignee_logins(updated)

    Enum.map(now -- was, &{"assigned", "assigned:#{&1}", {:login, &1}}) ++
      Enum.map(was -- now, &{"unassigned", "unassigned:#{&1}", {:login, &1}})
  end

  defp label_events(before, updated) do
    was = label_names(before)
    now = label_names(updated)

    Enum.map(now -- was, &{"labeled", "labeled:#{&1}", :subscribers}) ++
      Enum.map(was -- now, &{"unlabeled", "unlabeled:#{&1}", :subscribers})
  end

  defp assignee_logins(%Issue{assignees: assignees}),
    do: assignees |> List.wrap() |> Enum.map(&String.downcase(entry(&1, "login"))) |> Enum.uniq()

  defp label_names(%Issue{labels: labels}),
    do: labels |> List.wrap() |> Enum.map(&String.downcase(entry(&1, "name"))) |> Enum.uniq()

  # The JSON columns come back from PostgreSQL with string keys and are built
  # in memory with them too, but a caller can hand `update_issue/3` a map keyed
  # either way. Comparing stringified keys reads both without turning a value
  # from a request body into an atom.
  defp entry(map, key) when is_map(map) do
    Enum.find_value(map, "", fn {found, value} -> to_string(found) == key && to_string(value) end)
  end

  defp entry(_map, _key), do: ""

  # The transition has no row of its own, so the key is the issue, the second
  # the update landed on, and the field with its new value. A retried request
  # derives no event at all — the second attempt sees the change already
  # applied and the difference is empty — and two writers racing to the same
  # transition in the same second collide on this key instead of notifying
  # twice.
  defp deliver_event(%Issue{} = issue, repository, actor, {kind, fragment, audience}) do
    dedupe_key = "issue:#{issue.id}:#{DateTime.to_unix(issue.updated_at)}:#{fragment}"
    actor_login = actor_login(actor)
    actor_id = author_id(actor)

    readers =
      audience
      |> recipients(issue)
      |> Enum.filter(&readable?(repository, &1))

    # Being handed an issue makes you a follower of it. The subscription is
    # written before the preference filter, because muting the announcement is
    # not the same as declining the work.
    if kind == "assigned", do: Enum.each(readers, &subscribe(issue, &1, "assigned"))

    readers
    |> Enum.reject(&(&1.id == actor_id))
    |> Enum.filter(&enabled?(&1, kind))
    |> Enum.map(fn user ->
      insert_notification(user, issue, nil, kind, actor_login, dedupe_key)
      enqueue_email(user, issue, kind, actor_login, dedupe_key)
      user.id
    end)
  end

  defp recipients(:subscribers, %Issue{} = issue), do: subscribers(issue)

  defp recipients({:login, login}, _issue) do
    Repo.all(
      from user in User,
        where: fragment("lower(?)", user.github_login) == ^login and user.status == "active"
    )
  end

  defp subscribe_author(issue, %User{} = author, reason), do: subscribe(issue, author, reason)
  defp subscribe_author(_issue, _author, _reason), do: :ok

  # One pass per event. Mentions are resolved first so they claim their
  # recipients before the subscriber sweep, then both sets are filtered by
  # readability and by the recipient's own preference, then written under one
  # dedupe key per recipient.
  defp deliver(%Issue{} = issue, comment, author, dedupe_key, body) do
    repository = Repo.get(Repository, issue.repository_id)
    actor_login = actor_login(author)
    author_id = author_id(author)

    mentioned = mentioned_users(body, issue.repository_id)
    mentioned_ids = MapSet.new(mentioned, & &1.id)

    subscribers =
      if comment do
        issue |> subscribers() |> Enum.reject(&MapSet.member?(mentioned_ids, &1.id))
      else
        []
      end

    # Being mentioned also starts a subscription, so the next comment on the
    # thread reaches the person who was pulled into it.
    Enum.each(mentioned, &subscribe(issue, &1, "mentioned"))

    rows =
      Enum.map(mentioned, &{&1, "mention"}) ++ Enum.map(subscribers, &{&1, "issue_comment"})

    rows
    |> Enum.reject(fn {user, _kind} -> user.id == author_id end)
    |> Enum.filter(fn {user, kind} -> enabled?(user, kind) end)
    |> Enum.filter(fn {user, _kind} -> readable?(repository, user) end)
    |> Enum.map(fn {user, kind} ->
      insert_notification(user, issue, comment, kind, actor_login, dedupe_key)
      enqueue_email(user, issue, kind, actor_login, dedupe_key)
      user.id
    end)
  end

  # The email half, asked for in the same transaction as the record it
  # announces. The four conditions are re-decided at send time by
  # `email_dispatch/1`; checking them here as well keeps the queue from filling
  # with effects for accounts that were never going to be mailed.
  defp enqueue_email(%User{} = user, %Issue{} = issue, kind, actor_login, dedupe_key) do
    if email_wanted?(user, kind) do
      Delivery.enqueue(
        dedupe_key: dedupe_key,
        user_id: user.id,
        issue_id: issue.id,
        kind: kind,
        actor_login: actor_login
      )
    end

    :ok
  end

  defp email_wanted?(%User{} = user, kind) do
    kind in @email_kinds and EmailChannel.deliverable?() and
      not is_nil(EmailChannel.verified_address(user)) and preferences(user).email_enabled
  end

  defp insert_notification(user, issue, comment, kind, actor_login, dedupe_key) do
    %Notification{}
    |> Notification.changeset(%{
      kind: kind,
      actor_login: actor_login,
      dedupe_key: dedupe_key
    })
    |> Ecto.Changeset.put_change(:user_id, user.id)
    |> Ecto.Changeset.put_change(:repository_id, issue.repository_id)
    |> Ecto.Changeset.put_change(:issue_id, issue.id)
    |> Ecto.Changeset.put_change(:comment_id, comment && comment.id)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :dedupe_key])
  end

  defp mentioned_users(body, _repository_id) do
    case Mentions.extract(body) do
      [] ->
        []

      logins ->
        bounded = Enum.take(logins, @mention_limit)

        Repo.all(
          from user in User,
            where: fragment("lower(?)", user.github_login) in ^bounded and user.status == "active"
        )
    end
  end

  defp subscribers(%Issue{} = issue) do
    Repo.all(
      from subscription in IssueSubscription,
        join: user in User,
        on: user.id == subscription.user_id,
        where:
          subscription.issue_id == ^issue.id and subscription.subscribed == true and
            user.status == "active",
        select: user
    )
  end

  # The canonical predicate, composed rather than restated. A private
  # repository admits its members and nobody else, and this is the only place
  # fan-out decides that.
  defp readable?(nil, _user), do: false

  defp readable?(%Repository{id: repository_id}, %User{} = user) do
    Repository
    |> Repositories.readable_by(user)
    |> where([repository], repository.id == ^repository_id)
    |> Repo.exists?()
  end

  defp enabled?(%User{} = user, kind), do: category_enabled(preferences(user), kind)

  defp category_enabled(preferences, "mention"), do: preferences.mentions_enabled
  defp category_enabled(preferences, "issue_comment"), do: preferences.issue_comments_enabled
  defp category_enabled(preferences, "assigned"), do: preferences.assignments_enabled
  defp category_enabled(preferences, "unassigned"), do: preferences.assignments_enabled
  defp category_enabled(preferences, "labeled"), do: preferences.label_changes_enabled
  defp category_enabled(preferences, "unlabeled"), do: preferences.label_changes_enabled
  defp category_enabled(preferences, "state_changed"), do: preferences.issue_activity_enabled

  defp actor_login(%User{github_login: login}), do: login
  defp actor_login(%{handle: handle}) when is_binary(handle), do: handle
  defp actor_login(_author), do: nil

  defp author_id(%User{id: id}), do: id
  defp author_id(_author), do: nil

  ## Reading

  @doc """
  One recipient's notifications, newest first, bounded to one page.

  Every row is re-checked against the repository the recipient can read now,
  not the one they could read when it was written.
  """
  def list_notifications(user, opts \\ [])

  def list_notifications(%User{} = user, opts) when is_list(opts) do
    user
    |> visible_query(opts)
    |> order_by([notification], desc: notification.inserted_at, desc: notification.id)
    |> limit(^@notifications_per_page)
    |> preload([:issue, :repository, :comment])
    |> Repo.all()
  end

  def list_notifications(nil, _opts), do: []

  @doc "How many unread notifications the recipient can currently read."
  def unread_count(%User{} = user) do
    user
    |> visible_query(unread: true)
    |> Repo.aggregate(:count)
  end

  def unread_count(nil), do: 0

  defp visible_query(%User{} = user, opts) do
    query =
      from notification in Notification,
        join: repository in subquery(Repositories.readable_by(Repository, user)),
        on: repository.id == notification.repository_id,
        where: notification.user_id == ^user.id

    if Keyword.get(opts, :unread, false) do
      where(query, [notification], is_nil(notification.read_at))
    else
      query
    end
  end

  @doc """
  Marks one notification read.

  Scoped to the recipient, so an identifier from another account's inbox
  changes nothing.
  """
  def mark_read(%User{} = user, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        {count, _} =
          Notification
          |> where([notification], notification.id == ^uuid and notification.user_id == ^user.id)
          |> where([notification], is_nil(notification.read_at))
          |> Repo.update_all(set: [read_at: now, updated_at: now])

        if count > 0, do: broadcast_unread(user)

        {:ok, count}

      :error ->
        {:ok, 0}
    end
  end

  @doc "Marks every unread notification read for one recipient."
  def mark_all_read(%User{} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Notification
      |> where([notification], notification.user_id == ^user.id and is_nil(notification.read_at))
      |> Repo.update_all(set: [read_at: now, updated_at: now])

    if count > 0, do: broadcast_unread(user)

    {:ok, count}
  end

  ## Preferences

  @doc """
  The recipient's delivery categories.

  A missing row is the default rather than an error, so an account that never
  visited the settings surface behaves like one that accepted the defaults.
  """
  def preferences(%User{} = user) do
    Repo.get_by(Preference, user_id: user.id) || %Preference{user_id: user.id}
  end

  @doc "Turns delivery categories on or off for one recipient."
  def update_preferences(%User{} = user, attrs) do
    existing = preferences(user)

    changeset =
      existing
      |> Preference.changeset(attrs)
      |> Ecto.Changeset.put_change(:user_id, user.id)

    case existing do
      %Preference{id: nil} ->
        Repo.insert(changeset,
          on_conflict: {:replace, Preference.switches() ++ [:updated_at]},
          conflict_target: [:user_id]
        )

      %Preference{} ->
        Repo.update(changeset)
    end
  end

  @doc "Whether the account has an explicit preference row."
  def preferences_recorded?(%User{} = user) do
    Repo.exists?(from preference in Preference, where: preference.user_id == ^user.id)
  end

  ## Outbound

  @doc """
  Resolves a queued `email.delivery` payload to a recipient and a pointer.

  Every question the enqueue answered is asked again here, against the database
  as it is now rather than as it was when the comment landed: is the account
  still active, is its address still confirmed, is the channel still on, is the
  category still on, and can it still read the repository. A queued message
  therefore cannot outlive the consent or the access it was queued under, which
  matters precisely because a sent message is the one notification no later
  authorization check can withdraw.

  A `{:refused, outcome}` is a completion, not a failure: none of these answers
  changes by being asked again in eight seconds. The outcome string is recorded
  on the effect, so the queue says why it sent nothing.

  The pointer carries what NOTIFY-001 lets a notification carry — the kind, the
  actor's login, the repository path, and the issue number — plus the two URLs
  a message needs to be useful. The issue's title is not in it.
  """
  @spec email_dispatch(map()) :: {:ok, String.t(), map()} | {:refused, String.t()}
  def email_dispatch(payload) when is_map(payload) do
    with {:ok, user} <- dispatch_user(payload["user_id"]),
         {:ok, address} <- dispatch_address(user),
         preferences = preferences(user),
         :ok <- dispatch_channel(preferences),
         :ok <- dispatch_category(preferences, payload["kind"]),
         {:ok, issue} <- dispatch_issue(payload["issue_id"]),
         {:ok, repository} <- dispatch_repository(issue, user) do
      {:ok, address, pointer(payload, issue, repository)}
    end
  end

  defp dispatch_user(user_id) when is_binary(user_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(user_id),
         %User{status: "active"} = user <- Repo.get(User, uuid) do
      {:ok, user}
    else
      _absent -> {:refused, "recipient_gone"}
    end
  end

  defp dispatch_user(_user_id), do: {:refused, "recipient_gone"}

  defp dispatch_address(user) do
    case EmailChannel.verified_address(user) do
      nil -> {:refused, "no_verified_address"}
      address -> {:ok, address}
    end
  end

  defp dispatch_channel(%Preference{email_enabled: true}), do: :ok
  defp dispatch_channel(%Preference{}), do: {:refused, "channel_off"}

  defp dispatch_category(preferences, kind) when kind in @email_kinds do
    if category_enabled(preferences, kind), do: :ok, else: {:refused, "category_off"}
  end

  defp dispatch_category(_preferences, _kind), do: {:refused, "kind_not_carried"}

  # The issue's key is an integer, so the payload carries one and this reads it
  # back as one. Anything else is a payload this release did not write.
  defp dispatch_issue(issue_id) when is_integer(issue_id) do
    case Repo.get(Issue, issue_id) do
      %Issue{} = issue -> {:ok, issue}
      nil -> {:refused, "issue_gone"}
    end
  end

  defp dispatch_issue(_issue_id), do: {:refused, "issue_gone"}

  defp dispatch_repository(%Issue{repository_id: repository_id}, user) do
    repository = Repo.get(Repository, repository_id)

    if readable?(repository, user), do: {:ok, repository}, else: {:refused, "not_readable"}
  end

  defp pointer(payload, issue, repository) do
    base = String.trim_trailing(OpenAgentsWeb.Endpoint.url(), "/")
    path = "#{repository.owner}/#{repository.name}"

    %{
      "kind" => payload["kind"],
      "actor_login" => payload["actor_login"],
      "repository" => path,
      "issue_number" => issue.number,
      "url" => "#{base}/#{path}/issues/#{issue.number}",
      "settings_url" => "#{base}/notifications"
    }
  end
end
