defmodule OpenAgents.NotificationsTest do
  use OpenAgents.DataCase, async: true

  import OpenAgents.AccountsFixtures
  import OpenAgents.IssuesFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Notifications
  alias OpenAgents.Notifications.Mentions
  alias OpenAgents.Repositories

  describe "mention extraction" do
    test "reads a login out of prose" do
      assert Mentions.extract("thanks @octocat, shipping now") == ["octocat"]
    end

    test "downcases and deduplicates" do
      assert Mentions.extract("@Octocat and @octocat and @OCTOCAT") == ["octocat"]
    end

    test "ignores a login inside an inline code span" do
      assert Mentions.extract("run `git config user.name @octocat` first") == []
    end

    test "ignores a login inside a fenced block" do
      body = """
      Here is the transcript:

      ```
      ssh @octocat@example.com
      ```

      and nothing else
      """

      assert Mentions.extract(body) == []
    end

    test "ignores an email address and a path" do
      assert Mentions.extract("mail me at someone@octocat or see docs/@octocat") == []
    end

    test "accepts inner hyphens but not a trailing one" do
      assert Mentions.extract("@open-agents-inc") == ["open-agents-inc"]
      assert Mentions.extract("@octocat- done") == ["octocat"]
    end

    test "returns an empty list for a blank body" do
      assert Mentions.extract(nil) == []
      assert Mentions.extract("") == []
    end
  end

  describe "subscriptions" do
    setup do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author)
      issue = issue_fixture(repository, %{title: "a title"})

      %{author: author, repository: repository, issue: issue}
    end

    test "an author follows the issue they opened", %{repository: repository} do
      opener = repository_user_fixture("opener-#{System.unique_integer([:positive])}")
      {:ok, _member} = Repositories.add_member(repository, opener, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "opened by me"}, opener)

      assert Notifications.subscribed?(issue, opener)
    end

    test "a commenter follows the issue they commented on", %{
      issue: issue,
      repository: repository
    } do
      commenter = repository_user_fixture("commenter-#{System.unique_integer([:positive])}")
      {:ok, _member} = Repositories.add_member(repository, commenter, "contributor")

      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "looking"}, commenter)

      assert Notifications.subscribed?(issue, commenter)
    end

    test "unsubscribing survives commenting again", %{issue: issue, repository: repository} do
      muter = repository_user_fixture("muter-#{System.unique_integer([:positive])}")
      {:ok, _member} = Repositories.add_member(repository, muter, "contributor")

      {:ok, _subscription} = Notifications.unsubscribe(issue, muter)
      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "one more"}, muter)

      refute Notifications.subscribed?(issue, muter)
    end

    test "an explicit subscribe overrides an earlier mute", %{issue: issue, author: author} do
      {:ok, _muted} = Notifications.unsubscribe(issue, author)
      {:ok, _resubscribed} = Notifications.subscribe(issue, author, "manual")

      assert Notifications.subscribed?(issue, author)
    end
  end

  describe "comment fan-out" do
    setup do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, author)

      %{author: author, watcher: watcher, repository: repository, issue: issue}
    end

    test "a subscriber hears about a new comment", %{
      author: author,
      watcher: watcher,
      issue: issue
    } do
      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "a first look"}, watcher)

      assert [notification] = Notifications.list_notifications(author)
      assert notification.kind == "issue_comment"
      assert notification.issue_id == issue.id
      assert notification.actor_login == watcher.github_login
      assert is_nil(notification.read_at)
    end

    test "the commenter is never notified about their own comment", %{
      watcher: watcher,
      issue: issue
    } do
      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "talking to myself"}, watcher)

      assert Notifications.list_notifications(watcher) == []
    end

    test "a mention notifies somebody who never touched the issue", %{
      repository: repository,
      author: author,
      issue: issue
    } do
      stranger = repository_user_fixture("stranger-#{System.unique_integer([:positive])}")
      {:ok, _member} = Repositories.add_member(repository, stranger, "viewer")

      {:ok, _comment} =
        Issues.create_comment(issue, %{"body" => "@#{stranger.github_login} take a look"}, author)

      assert [notification] = Notifications.list_notifications(stranger)
      assert notification.kind == "mention"
    end

    test "a mention also starts a subscription", %{
      repository: repository,
      author: author,
      issue: issue
    } do
      stranger = repository_user_fixture("stranger-#{System.unique_integer([:positive])}")
      {:ok, _member} = Repositories.add_member(repository, stranger, "viewer")

      {:ok, _comment} =
        Issues.create_comment(issue, %{"body" => "@#{stranger.github_login} ping"}, author)

      assert Notifications.subscribed?(issue, stranger)
    end

    test "a subscriber who is also mentioned gets exactly one record, as a mention", %{
      author: author,
      watcher: watcher,
      issue: issue
    } do
      {:ok, _comment} =
        Issues.create_comment(issue, %{"body" => "@#{author.github_login} over to you"}, watcher)

      assert [notification] = Notifications.list_notifications(author)
      assert notification.kind == "mention"
    end

    test "a mention in the issue body notifies on open", %{
      repository: repository,
      author: author
    } do
      stranger = repository_user_fixture("stranger-#{System.unique_integer([:positive])}")
      {:ok, _member} = Repositories.add_member(repository, stranger, "viewer")

      {:ok, issue} =
        Issues.create_issue(
          repository,
          %{title: "needs review", body: "@#{stranger.github_login} thoughts?"},
          author
        )

      assert [notification] = Notifications.list_notifications(stranger)
      assert notification.kind == "mention"
      assert notification.issue_id == issue.id
      assert is_nil(notification.comment_id)
    end

    test "a mention of a login that is not an account notifies nobody", %{
      author: author,
      issue: issue
    } do
      {:ok, _comment} =
        Issues.create_comment(issue, %{"body" => "@nobody-has-this-login here"}, author)

      assert Notifications.list_notifications(author) == []
    end
  end

  describe "authorization" do
    test "a private repository never notifies a reader who lost membership" do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      reader = repository_user_fixture("reader-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author, %{visibility: "private"})
      {:ok, _member} = Repositories.add_member(repository, reader, "viewer")

      {:ok, issue} = Issues.create_issue(repository, %{title: "internal"}, author)
      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "an update"}, reader)
      {:ok, _second} = Issues.create_comment(issue, %{"body" => "another update"}, author)

      assert [_notification] = Notifications.list_notifications(reader)

      :ok = Repositories.remove_member(repository, author, reader.id)

      assert Notifications.list_notifications(reader) == []
      assert Notifications.unread_count(reader) == 0
    end

    test "a mention in a private repository never reaches a non-member" do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      outsider = repository_user_fixture("outsider-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author, %{visibility: "private"})

      {:ok, issue} = Issues.create_issue(repository, %{title: "internal"}, author)

      {:ok, _comment} =
        Issues.create_comment(issue, %{"body" => "@#{outsider.github_login} look"}, author)

      assert Notifications.list_notifications(outsider) == []
      assert Notifications.unread_count(outsider) == 0
    end

    test "a mention in a public repository reaches a non-member" do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      outsider = repository_user_fixture("outsider-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author, %{visibility: "public"})

      {:ok, issue} = Issues.create_issue(repository, %{title: "open to all"}, author)

      {:ok, _comment} =
        Issues.create_comment(issue, %{"body" => "@#{outsider.github_login} look"}, author)

      assert [notification] = Notifications.list_notifications(outsider)
      assert notification.kind == "mention"
    end

    test "one account cannot mark another account's notification read" do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      intruder = repository_user_fixture("intruder-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, author)
      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "hello"}, watcher)

      assert [notification] = Notifications.list_notifications(author)

      assert {:ok, 0} = Notifications.mark_read(intruder, notification.id)
      assert Notifications.unread_count(author) == 1
    end

    test "a malformed identifier marks nothing read" do
      user = repository_user_fixture("user-#{System.unique_integer([:positive])}")
      assert {:ok, 0} = Notifications.mark_read(user, "not-a-uuid")
    end
  end

  describe "idempotency" do
    test "replaying the same fan-out writes one record" do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, author)
      {:ok, comment} = Issues.create_comment(issue, %{"body" => "hello"}, watcher)

      assert [_one] = Notifications.list_notifications(author)

      Notifications.comment_created(issue, comment, watcher)
      Notifications.comment_created(issue, comment, watcher)

      assert [_still_one] = Notifications.list_notifications(author)
      assert Notifications.unread_count(author) == 1
    end

    test "a replay after the record was read does not resurrect it as unread" do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, author)
      {:ok, comment} = Issues.create_comment(issue, %{"body" => "hello"}, watcher)

      {:ok, 1} = Notifications.mark_all_read(author)
      assert Notifications.unread_count(author) == 0

      Notifications.comment_created(issue, comment, watcher)

      assert Notifications.unread_count(author) == 0
    end

    test "two different comments produce two records" do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, author)
      {:ok, _first} = Issues.create_comment(issue, %{"body" => "one"}, watcher)
      {:ok, _second} = Issues.create_comment(issue, %{"body" => "two"}, watcher)

      assert Notifications.unread_count(author) == 2
    end
  end

  describe "preferences" do
    setup do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")
      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, author)

      %{author: author, watcher: watcher, repository: repository, issue: issue}
    end

    test "every category but label changes is on for an account that never chose", %{
      author: author
    } do
      preferences = Notifications.preferences(author)

      assert preferences.mentions_enabled
      assert preferences.issue_comments_enabled
      assert preferences.assignments_enabled
      assert preferences.issue_activity_enabled
      refute preferences.label_changes_enabled
      refute Notifications.preferences_recorded?(author)
    end

    test "turning issue comments off stops subscriber delivery", %{
      author: author,
      watcher: watcher,
      issue: issue
    } do
      {:ok, _preferences} =
        Notifications.update_preferences(author, %{issue_comments_enabled: false})

      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "an update"}, watcher)

      assert Notifications.list_notifications(author) == []
    end

    test "turning issue comments off leaves mentions working", %{
      author: author,
      watcher: watcher,
      issue: issue
    } do
      {:ok, _preferences} =
        Notifications.update_preferences(author, %{issue_comments_enabled: false})

      {:ok, _comment} =
        Issues.create_comment(issue, %{"body" => "@#{author.github_login} still here"}, watcher)

      assert [notification] = Notifications.list_notifications(author)
      assert notification.kind == "mention"
    end

    test "turning mentions off stops mention delivery", %{
      author: author,
      watcher: watcher,
      issue: issue
    } do
      {:ok, _preferences} = Notifications.update_preferences(author, %{mentions_enabled: false})
      {:ok, _muted} = Notifications.unsubscribe(issue, author)

      {:ok, _comment} =
        Issues.create_comment(issue, %{"body" => "@#{author.github_login} hello"}, watcher)

      assert Notifications.list_notifications(author) == []
    end

    test "a second update rewrites the same row", %{author: author} do
      {:ok, _first} = Notifications.update_preferences(author, %{mentions_enabled: false})
      {:ok, second} = Notifications.update_preferences(author, %{mentions_enabled: true})

      assert second.mentions_enabled
      assert Notifications.preferences_recorded?(author)
      assert Notifications.preferences(author).mentions_enabled
    end
  end

  describe "reading" do
    setup do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")
      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, author)

      %{author: author, watcher: watcher, issue: issue}
    end

    test "marking one read leaves the rest unread", %{
      author: author,
      watcher: watcher,
      issue: issue
    } do
      {:ok, _first} = Issues.create_comment(issue, %{"body" => "one"}, watcher)
      {:ok, _second} = Issues.create_comment(issue, %{"body" => "two"}, watcher)

      [newest | _rest] = Notifications.list_notifications(author)

      assert {:ok, 1} = Notifications.mark_read(author, newest.id)
      assert Notifications.unread_count(author) == 1
    end

    test "marking the same record read twice counts once", %{
      author: author,
      watcher: watcher,
      issue: issue
    } do
      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "one"}, watcher)
      [notification] = Notifications.list_notifications(author)

      assert {:ok, 1} = Notifications.mark_read(author, notification.id)
      assert {:ok, 0} = Notifications.mark_read(author, notification.id)
    end

    test "an anonymous reader has an empty inbox" do
      assert Notifications.list_notifications(nil) == []
      assert Notifications.unread_count(nil) == 0
    end
  end

  describe "issue event fan-out" do
    setup do
      actor = repository_user_fixture("actor-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(actor)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, watcher)

      %{actor: actor, watcher: watcher, repository: repository, issue: issue}
    end

    test "closing an issue reaches a subscriber", %{
      actor: actor,
      watcher: watcher,
      issue: issue
    } do
      {:ok, _closed} = Issues.update_issue(issue, %{"state" => "closed"}, actor)

      assert [notification] = Notifications.list_notifications(watcher)
      assert notification.kind == "state_changed"
      assert notification.issue_id == issue.id
      assert notification.actor_login == actor.github_login
      assert is_nil(notification.comment_id)
    end

    test "reopening reaches a subscriber as a second record", %{
      actor: actor,
      watcher: watcher,
      issue: issue
    } do
      {:ok, closed} = Issues.update_issue(issue, %{"state" => "closed"}, actor)
      {:ok, _reopened} = Issues.update_issue(closed, %{"state" => "open"}, actor)

      assert [_reopen, _close] = Notifications.list_notifications(watcher)
      assert Notifications.unread_count(watcher) == 2
    end

    test "editing the title announces nothing", %{actor: actor, watcher: watcher, issue: issue} do
      {:ok, _renamed} = Issues.update_issue(issue, %{"title" => "a better title"}, actor)

      assert Notifications.list_notifications(watcher) == []
    end

    test "labelling reaches a subscriber who asked for label changes", %{
      actor: actor,
      watcher: watcher,
      issue: issue
    } do
      {:ok, _preferences} =
        Notifications.update_preferences(watcher, %{label_changes_enabled: true})

      {:ok, labelled} = Issues.add_labels(issue, ["bug"], actor)

      assert [notification] = Notifications.list_notifications(watcher)
      assert notification.kind == "labeled"

      {:ok, _unlabelled} = Issues.remove_label(labelled, "bug", actor)

      assert kinds(watcher) == ~w(labeled unlabeled)
    end

    test "labelling reaches nobody by default", %{actor: actor, watcher: watcher, issue: issue} do
      {:ok, _labelled} = Issues.add_labels(issue, ["bug"], actor)

      assert Notifications.list_notifications(watcher) == []
    end

    test "assignment reaches the assignee who never followed the issue", %{
      actor: actor,
      repository: repository,
      issue: issue
    } do
      stranger = repository_user_fixture("stranger-#{System.unique_integer([:positive])}")
      {:ok, _member} = Repositories.add_member(repository, stranger, "contributor")

      refute Notifications.subscribed?(issue, stranger)

      {:ok, _assigned} = Issues.add_assignees(issue, [stranger.github_login], actor)

      assert [notification] = Notifications.list_notifications(stranger)
      assert notification.kind == "assigned"
      assert notification.actor_login == actor.github_login
    end

    test "assignment starts the assignee following the issue", %{
      actor: actor,
      repository: repository,
      issue: issue
    } do
      stranger = repository_user_fixture("stranger-#{System.unique_integer([:positive])}")
      {:ok, _member} = Repositories.add_member(repository, stranger, "contributor")

      {:ok, assigned} = Issues.add_assignees(issue, [stranger.github_login], actor)

      assert Notifications.subscribed?(assigned, stranger)

      {:ok, _comment} = Issues.create_comment(assigned, %{"body" => "over to you"}, actor)

      assert kinds(stranger) == ~w(assigned issue_comment)
    end

    test "unassignment reaches the account taken off", %{
      actor: actor,
      repository: repository,
      issue: issue
    } do
      stranger = repository_user_fixture("stranger-#{System.unique_integer([:positive])}")
      {:ok, _member} = Repositories.add_member(repository, stranger, "contributor")

      {:ok, assigned} = Issues.add_assignees(issue, [stranger.github_login], actor)
      {:ok, _removed} = Issues.remove_assignees(assigned, [stranger.github_login], actor)

      assert kinds(stranger) == ~w(assigned unassigned)
    end

    test "assigning yourself announces nothing to yourself", %{
      watcher: watcher,
      issue: issue
    } do
      {:ok, _assigned} = Issues.add_assignees(issue, [watcher.github_login], watcher)

      assert Notifications.list_notifications(watcher) == []
    end

    test "turning assignments off stops delivery to the assignee", %{
      actor: actor,
      repository: repository,
      issue: issue
    } do
      stranger = repository_user_fixture("stranger-#{System.unique_integer([:positive])}")
      {:ok, _member} = Repositories.add_member(repository, stranger, "contributor")

      {:ok, _preferences} =
        Notifications.update_preferences(stranger, %{assignments_enabled: false})

      {:ok, _assigned} = Issues.add_assignees(issue, [stranger.github_login], actor)

      assert Notifications.list_notifications(stranger) == []
    end

    test "turning issue activity off stops state changes but leaves comments", %{
      actor: actor,
      watcher: watcher,
      issue: issue
    } do
      {:ok, _preferences} =
        Notifications.update_preferences(watcher, %{issue_activity_enabled: false})

      {:ok, closed} = Issues.update_issue(issue, %{"state" => "closed"}, actor)
      {:ok, _comment} = Issues.create_comment(closed, %{"body" => "done"}, actor)

      assert [%{kind: "issue_comment"}] = Notifications.list_notifications(watcher)
    end

    test "an unattributed close still reaches the subscriber", %{
      watcher: watcher,
      issue: issue
    } do
      {:ok, _closed} = Issues.update_issue(issue, %{"state" => "closed"})

      assert [notification] = Notifications.list_notifications(watcher)
      assert notification.kind == "state_changed"
      assert is_nil(notification.actor_login)
    end
  end

  describe "issue event authorization" do
    test "a private repository never notifies a subscriber who is no longer a member" do
      owner = repository_user_fixture("owner-#{System.unique_integer([:positive])}")
      former = repository_user_fixture("former-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(owner, %{visibility: "private"})
      {:ok, _member} = Repositories.add_member(repository, former, "contributor")

      # Following the issue while a member, then losing membership. The
      # subscription row survives, so nothing but fan-out's own predicate
      # stands between this account and a record about a private issue.
      {:ok, issue} = Issues.create_issue(repository, %{title: "internal"}, former)
      :ok = Repositories.remove_member(repository, owner, former.id)

      assert Notifications.subscribed?(issue, former)

      {:ok, _closed} = Issues.update_issue(issue, %{"state" => "closed"}, owner)

      assert Notifications.list_notifications(former) == []
      assert Notifications.unread_count(former) == 0
    end

    test "assigning an account that cannot write the repository is refused before fan-out" do
      owner = repository_user_fixture("owner-#{System.unique_integer([:positive])}")
      outsider = repository_user_fixture("outsider-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(owner, %{visibility: "private"})

      {:ok, issue} = Issues.create_issue(repository, %{title: "internal"}, owner)

      assert_raise Ecto.NoResultsError, fn ->
        Issues.update_issue(
          issue,
          %{"assignees" => [%{"login" => outsider.github_login}]},
          owner
        )
      end

      assert Notifications.list_notifications(outsider) == []
    end

    test "an event notification disappears when the recipient's membership ends" do
      owner = repository_user_fixture("owner-#{System.unique_integer([:positive])}")
      reader = repository_user_fixture("reader-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(owner, %{visibility: "private"})
      {:ok, _member} = Repositories.add_member(repository, reader, "viewer")

      {:ok, issue} = Issues.create_issue(repository, %{title: "internal"}, reader)
      {:ok, _closed} = Issues.update_issue(issue, %{"state" => "closed"}, owner)

      assert [%{kind: "state_changed"}] = Notifications.list_notifications(reader)

      :ok = Repositories.remove_member(repository, owner, reader.id)

      assert Notifications.list_notifications(reader) == []
      assert Notifications.unread_count(reader) == 0
    end
  end

  describe "issue event idempotency" do
    test "replaying the same derivation writes one record" do
      actor = repository_user_fixture("actor-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(actor)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, watcher)
      {:ok, closed} = Issues.update_issue(issue, %{"state" => "closed"}, actor)

      assert Notifications.unread_count(watcher) == 1

      Notifications.issue_updated(issue, closed, actor)
      Notifications.issue_updated(issue, closed, actor)

      assert Notifications.unread_count(watcher) == 1
    end

    test "a replay after the record was read does not resurrect it as unread" do
      actor = repository_user_fixture("actor-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(actor)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, watcher)
      {:ok, closed} = Issues.update_issue(issue, %{"state" => "closed"}, actor)

      {:ok, 1} = Notifications.mark_all_read(watcher)

      Notifications.issue_updated(issue, closed, actor)

      assert Notifications.unread_count(watcher) == 0
    end

    test "closing an already closed issue derives nothing" do
      actor = repository_user_fixture("actor-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(actor)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, watcher)
      {:ok, closed} = Issues.update_issue(issue, %{"state" => "closed"}, actor)
      {:ok, _again} = Issues.update_issue(closed, %{"state" => "closed"}, actor)

      assert Notifications.unread_count(watcher) == 1
    end
  end

  describe "the unread count" do
    test "counts past the page the inbox loads" do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a busy thread"}, author)

      over_a_page = Notifications.per_page() + 5

      Enum.each(1..over_a_page, fn n ->
        {:ok, _comment} = Issues.create_comment(issue, %{"body" => "note #{n}"}, watcher)
      end)

      # The count is an aggregate over the same authorized query the inbox
      # composes, not the size of what the inbox loaded. `length/1` over
      # `list_notifications/1` would stop at one page and report 50 for ever
      # after, which is the mistake this repository already removed from the
      # homepage once.
      assert length(Notifications.list_notifications(author)) == Notifications.per_page()
      assert Notifications.unread_count(author) == over_a_page
    end

    test "an unreadable repository is not counted" do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      reader = repository_user_fixture("reader-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author, %{visibility: "private"})
      {:ok, _member} = Repositories.add_member(repository, reader, "viewer")

      {:ok, issue} = Issues.create_issue(repository, %{title: "internal"}, reader)
      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "an update"}, author)

      assert Notifications.unread_count(reader) == 1

      :ok = Repositories.remove_member(repository, author, reader.id)

      assert Notifications.unread_count(reader) == 0
    end
  end

  describe "unread announcements" do
    test "a delivered notification announces the recipient's new count" do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, author)

      :ok = Notifications.subscribe_unread(author)

      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "hello"}, watcher)

      author_id = author.id
      assert_receive {:unread_notifications_changed, ^author_id}
    end

    test "a derived issue event announces the subscriber's new count" do
      actor = repository_user_fixture("actor-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(actor)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, watcher)

      :ok = Notifications.subscribe_unread(watcher)

      {:ok, _closed} = Issues.update_issue(issue, %{"state" => "closed"}, actor)

      watcher_id = watcher.id
      assert_receive {:unread_notifications_changed, ^watcher_id}
    end

    test "marking read announces the reader's new count" do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
      watcher = repository_user_fixture("watcher-#{System.unique_integer([:positive])}")
      repository = repository_with_member_fixture(author)
      {:ok, _member} = Repositories.add_member(repository, watcher, "contributor")

      {:ok, issue} = Issues.create_issue(repository, %{title: "a title"}, author)
      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "hello"}, watcher)

      :ok = Notifications.subscribe_unread(author)

      [notification] = Notifications.list_notifications(author)
      {:ok, 1} = Notifications.mark_read(author, notification.id)

      author_id = author.id
      assert_receive {:unread_notifications_changed, ^author_id}
    end

    test "marking nothing read announces nothing" do
      author = repository_user_fixture("author-#{System.unique_integer([:positive])}")

      :ok = Notifications.subscribe_unread(author)

      {:ok, 0} = Notifications.mark_all_read(author)

      refute_receive {:unread_notifications_changed, _user_id}, 50
    end
  end

  # Two events landing in the same second share an `inserted_at`, and the
  # tiebreak is a random UUID, so asserting on delivery order would assert on
  # nothing. Compare the set of kinds instead.
  defp kinds(user) do
    user |> Notifications.list_notifications() |> Enum.map(& &1.kind) |> Enum.sort()
  end
end
