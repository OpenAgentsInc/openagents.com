defmodule OpenAgents.Notifications.EmailDeliveryTest do
  @moduledoc """
  The email channel, end to end and at its edges.

  One mention travels the whole path: a comment names somebody, the fan-out
  writes a record and an `email.delivery` effect in the same transaction, the
  outbox worker claims it, and a message arrives addressed to the mailbox that
  account confirmed. The rest of the file is the other half of the claim —
  everybody who should get nothing, gets nothing:

    * an address that was typed but never confirmed
    * an account that never turned the channel on
    * an account that switched it off, or removed the address, after the enqueue
    * a kind the channel does not carry
    * a recipient who lost access to the repository after the enqueue

  The last three matter most. A sent message is the one notification no later
  authorization check can withdraw, so the checks have to run on the way out
  rather than only on the way in.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures
  import Swoosh.TestAssertions

  alias OpenAgents.Effects
  alias OpenAgents.Effects.Effect
  alias OpenAgents.Effects.Worker
  alias OpenAgents.Issues
  alias OpenAgents.Notifications
  alias OpenAgents.Notifications.EmailChannel
  alias OpenAgents.Repositories

  setup do
    author = repository_user_fixture("author-#{System.unique_integer([:positive])}")
    reader = repository_user_fixture("reader-#{System.unique_integer([:positive])}")
    repository = repository_with_member_fixture(author)
    {:ok, _member} = Repositories.add_member(repository, reader, "contributor")
    # Distinctive on purpose. "a title" could be absent from a message by
    # accident; this cannot, so the refutation below means something.
    title = "unrepeatable-title-#{System.unique_integer([:positive])}"
    {:ok, issue} = Issues.create_issue(repository, %{title: title}, author)

    %{author: author, reader: reader, repository: repository, issue: issue}
  end

  describe "a mention to a confirmed address" do
    setup %{reader: reader} do
      %{reader: subscribe_by_email(reader, "reader@example.com")}
    end

    test "is queued in the transaction that writes the record", %{
      author: author,
      reader: reader,
      issue: issue
    } do
      {:ok, _comment} = mention(issue, author, reader)

      assert [notification] = Notifications.list_notifications(reader)
      assert notification.kind == "mention"

      assert [effect] = deliveries()
      assert effect.payload["dedupe_key"] == notification.dedupe_key
      assert effect.payload["user_id"] == reader.id
      assert effect.payload["issue_id"] == issue.id
      assert effect.payload["kind"] == "mention"
      refute Map.has_key?(effect.payload, "to")
    end

    test "arrives at the confirmed mailbox, carrying a pointer and no title", %{
      author: author,
      reader: reader,
      repository: repository,
      issue: issue
    } do
      {:ok, _comment} = mention(issue, author, reader)

      drain()

      assert_receive {:email, email}
      assert email.to == [{"", "reader@example.com"}]
      assert email.from == {"OpenAgents", "notifications@openagents.com"}
      assert email.subject =~ author.github_login
      assert email.subject =~ "#{repository.owner}/#{repository.name}##{issue.number}"
      assert email.text_body =~ "/#{repository.owner}/#{repository.name}/issues/#{issue.number}"
      refute email.subject =~ issue.title
      refute email.text_body =~ issue.title

      assert [%{status: "done", result: %{"outcome" => "sent"}}] = deliveries()
    end

    test "a replayed fan-out is one record and one send", %{
      author: author,
      reader: reader,
      issue: issue
    } do
      {:ok, comment} = mention(issue, author, reader)
      Notifications.comment_created(issue, comment, author)

      assert length(Notifications.list_notifications(reader)) == 1
      assert length(deliveries()) == 1

      drain()

      assert_receive {:email, %Swoosh.Email{to: [{"", "reader@example.com"}]}}
      assert_no_email_sent()
    end
  end

  describe "who gets nothing" do
    test "an address that was typed but never confirmed", %{
      author: author,
      reader: reader,
      issue: issue
    } do
      {:ok, unconfirmed} = EmailChannel.set_address(reader, "reader@example.com")
      {:ok, _preferences} = Notifications.update_preferences(unconfirmed, %{email_enabled: true})
      assert_receive {:email, %Swoosh.Email{}}

      {:ok, _comment} = mention(issue, author, reader)

      assert [_notification] = Notifications.list_notifications(reader)
      assert deliveries() == []
      assert_no_email_sent()
    end

    test "an account that never turned the channel on", %{
      author: author,
      reader: reader,
      issue: issue
    } do
      confirm_address(reader, "reader@example.com")

      {:ok, _comment} = mention(issue, author, reader)

      assert [_notification] = Notifications.list_notifications(reader)
      assert deliveries() == []
      assert_no_email_sent()
    end

    test "an account that switched the channel off after the enqueue", %{
      author: author,
      reader: reader,
      issue: issue
    } do
      reader = subscribe_by_email(reader, "reader@example.com")
      {:ok, _comment} = mention(issue, author, reader)
      {:ok, _preferences} = Notifications.update_preferences(reader, %{email_enabled: false})

      drain()

      assert [%{status: "done", result: %{"outcome" => "channel_off"}}] = deliveries()
      assert_no_email_sent()
    end

    test "an account that removed the address after the enqueue", %{
      author: author,
      reader: reader,
      issue: issue
    } do
      reader = subscribe_by_email(reader, "reader@example.com")
      {:ok, _comment} = mention(issue, author, reader)
      {:ok, _removed} = EmailChannel.remove_address(reader)

      drain()

      assert [%{status: "done", result: %{"outcome" => "no_verified_address"}}] = deliveries()
      assert_no_email_sent()
    end

    test "a recipient who lost access to the repository after the enqueue", %{author: author} do
      dropped = repository_user_fixture("dropped-#{System.unique_integer([:positive])}")
      private = repository_with_member_fixture(author, %{visibility: "private"})
      {:ok, _member} = Repositories.add_member(private, dropped, "contributor")
      {:ok, issue} = Issues.create_issue(private, %{title: "a title"}, author)

      dropped = subscribe_by_email(dropped, "dropped@example.com")
      {:ok, _comment} = mention(issue, author, dropped)
      assert [_queued] = deliveries()

      :ok = Repositories.remove_member(private, author, dropped.id)

      drain()

      assert [%{status: "done", result: %{"outcome" => "not_readable"}}] = deliveries()
      assert_no_email_sent()
    end

    test "a kind the channel does not carry", %{
      author: author,
      reader: reader,
      issue: issue
    } do
      reader = subscribe_by_email(reader, "reader@example.com")
      {:ok, _subscription} = Notifications.subscribe(issue, reader, "manual")

      {:ok, _comment} = Issues.create_comment(issue, %{"body" => "no names here"}, author)

      assert [notification] = Notifications.list_notifications(reader)
      assert notification.kind == "issue_comment"
      assert deliveries() == []
      assert_no_email_sent()
    end
  end

  describe "a provider that cannot be reached" do
    defmodule FailingAdapter do
      @moduledoc false
      @behaviour OpenAgents.Notifications.Delivery.Adapter

      @impl true
      def deliver(_recipient, _data), do: {:error, :provider_unreachable}
    end

    setup do
      configured = Application.get_env(:openagents, OpenAgents.Notifications.Delivery)

      Application.put_env(:openagents, OpenAgents.Notifications.Delivery,
        adapter: __MODULE__.FailingAdapter
      )

      on_exit(fn ->
        Application.put_env(:openagents, OpenAgents.Notifications.Delivery, configured)
      end)

      :ok
    end

    test "leaves the delivery pending, and the outbox tries it again", %{
      author: author,
      reader: reader,
      issue: issue
    } do
      reader = subscribe_by_email(reader, "reader@example.com")
      {:ok, _comment} = mention(issue, author, reader)

      before = DateTime.utc_now()
      drain()

      assert [failed] = deliveries()
      assert failed.status == "pending"
      assert failed.attempts == 1
      assert failed.last_error =~ "provider_unreachable"
      assert DateTime.compare(failed.available_at, before) == :gt

      later = DateTime.add(failed.available_at, 1, :second)
      assert [retried] = Effects.claim_batch("worker-b", now: later)
      assert retried.attempts == 2
    end
  end

  defp mention(issue, author, reader) do
    Issues.create_comment(
      issue,
      %{"body" => "@#{reader.github_login} would you look at this"},
      author
    )
  end

  defp deliveries do
    Repo.all(from effect in Effect, where: effect.kind == "email.delivery")
  end

  defp drain do
    _pass = Worker.run_once(identity: "worker-#{System.unique_integer([:positive])}")
    :ok
  end

  defp subscribe_by_email(user, address) do
    verified = confirm_address(user, address)
    {:ok, _preferences} = Notifications.update_preferences(verified, %{email_enabled: true})
    verified
  end

  defp confirm_address(user, address) do
    {:ok, pending} = EmailChannel.set_address(user, address)
    assert_receive {:email, %Swoosh.Email{subject: subject}}
    code = hd(Regex.run(~r/[0-9A-Z]{8}/, subject))
    {:ok, verified} = EmailChannel.verify(pending, code)
    verified
  end
end
