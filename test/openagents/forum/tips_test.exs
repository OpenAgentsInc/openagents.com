defmodule OpenAgents.Forum.TipsTest do
  use OpenAgents.DataCase, async: true

  alias OpenAgents.Forum
  alias OpenAgents.Forum.{TipIntent, TipPaymentServiceStub, TipReceipt, Tips}

  setup do
    TipPaymentServiceStub.settle()
    :ok
  end

  defp user(login_prefix) do
    {:ok, user} =
      %OpenAgents.Accounts.User{}
      |> Ecto.Changeset.change(%{
        github_id: System.unique_integer([:positive]),
        github_login: "#{login_prefix}-#{System.unique_integer([:positive])}",
        github_name: "Tips Test",
        github_avatar_url: "https://example.com/a.png"
      })
      |> Repo.insert()

    user
  end

  defp forum do
    {:ok, forum} =
      %OpenAgents.Forum.Forum{}
      |> OpenAgents.Forum.Forum.changeset(%{
        slug: "general-#{System.unique_integer([:positive])}",
        title: "General"
      })
      |> Repo.insert()

    forum
  end

  # An author with a linked identity and a destination it controls: the only
  # shape a tip can be paid to.
  defp author(opts \\ []) do
    user = user("author")
    actor_ref = "agent:author-#{System.unique_integer([:positive])}"

    {:ok, link} = Forum.start_actor_link(user, actor_ref)
    {:ok, _linked} = Forum.approve_actor_link(link)

    if Keyword.get(opts, :destination, true) do
      {:ok, _destination} =
        Tips.register_destination(%{
          user_id: user.id,
          kind: "bolt12",
          destination: "lno1qsgz#{System.unique_integer([:positive])}",
          accepting_tips: Keyword.get(opts, :accepting_tips, true)
        })
    end

    %{user: user, actor_ref: actor_ref}
  end

  defp topic_with_post(author, title \\ "Hello") do
    {:ok, topic} =
      Forum.create_topic(forum(), %{
        title: title,
        slug: "hello-#{System.unique_integer([:positive])}",
        body_text: "First post",
        actor_ref: author.actor_ref,
        actor_display_name: "Author",
        actor_slug: "author"
      })

    [post] = Forum.list_posts(topic)
    {topic, post}
  end

  defp tip(post, payer, amount_sats, opts \\ []) do
    Tips.tip_post(%{
      post: post,
      payer_user: payer,
      payer_actor_ref: "user:#{payer.id}",
      amount_sats: amount_sats,
      idempotency_key: Keyword.get(opts, :idempotency_key, Ecto.UUID.generate())
    })
  end

  describe "destinations" do
    test "registering a destination retires the previous one" do
      user = user("recipient")

      {:ok, first} =
        Tips.register_destination(%{user_id: user.id, kind: "bolt12", destination: "lno1first"})

      {:ok, second} =
        Tips.register_destination(%{user_id: user.id, kind: "bolt12", destination: "lno1second"})

      assert Repo.reload!(first).state == "retired"
      assert Tips.active_destination(user.id).id == second.id
    end

    test "a destination is fingerprinted and never stores a wallet secret" do
      user = user("recipient")

      {:ok, destination} =
        Tips.register_destination(%{user_id: user.id, kind: "bolt12", destination: "lno1abcdef"})

      assert destination.fingerprint != "lno1abcdef"
      assert byte_size(destination.fingerprint) == 16

      assert {:error, changeset} =
               Tips.register_destination(%{
                 user_id: user("other").id,
                 kind: "bolt12",
                 destination: "seed words here"
               })

      assert %{destination: _errors} = errors_on(changeset)
    end

    test "opting out stops tips without discarding the destination" do
      author = author()
      {_topic, post} = topic_with_post(author)
      destination = Tips.active_destination(author.user.id)

      {:ok, _off} = Tips.set_accepting_tips(destination, false)

      assert {:error, :not_accepting_tips} = tip(post, user("payer"), 100)
    end

    test "a post whose author has no destination cannot be tipped" do
      author = author(destination: false)
      {_topic, post} = topic_with_post(author)

      assert {:error, :no_destination} = tip(post, user("payer"), 100)
    end
  end

  describe "tip_post/1" do
    test "settles a tip, records one receipt, and counts it for ranking" do
      author = author()
      {topic, post} = topic_with_post(author)

      assert {:ok, intent} = tip(post, user("payer"), 1_000)
      assert intent.state == "settled"
      assert intent.counted_sats == 1_000
      assert is_nil(intent.exclusion_reason)

      assert [%TipReceipt{kind: "settled", payment_hash: hash}] = Tips.list_receipts(intent)
      assert is_binary(hash)

      post = Repo.reload!(post)
      assert post.tip_sats_total == 1_000
      assert post.tip_sats_counted == 1_000
      assert post.tip_count == 1

      topic = Repo.reload!(topic)
      assert topic.tip_sats_total == 1_000
      assert topic.tip_sats_counted == 1_000
    end

    test "a retry with the same key pays once and counts once" do
      author = author()
      {_topic, post} = topic_with_post(author)
      payer = user("payer")
      key = Ecto.UUID.generate()

      assert {:ok, first} = tip(post, payer, 500, idempotency_key: key)
      assert {:ok, second} = tip(post, payer, 500, idempotency_key: key)

      assert first.id == second.id
      assert [_one_request] = TipPaymentServiceStub.requests()
      assert Repo.reload!(post).tip_sats_total == 500
      assert Repo.reload!(post).tip_count == 1
      assert [%TipReceipt{kind: "settled"}] = Tips.list_receipts(first)
    end

    test "a failed payment records the failure and counts nothing" do
      author = author()
      {topic, post} = topic_with_post(author)
      TipPaymentServiceStub.fail("no_route")

      assert {:error, {:payment_failed, intent}} = tip(post, user("payer"), 1_000)
      assert intent.state == "failed"
      assert intent.failure_code == "no_route"
      assert intent.counted_sats == 0

      assert [%TipReceipt{kind: "failed", failure_code: "no_route"}] = Tips.list_receipts(intent)
      assert Repo.reload!(post).tip_sats_total == 0
      assert Repo.reload!(topic).tip_sats_counted == 0
    end

    test "an unavailable payment service leaves the tip retryable and unpaid" do
      author = author()
      {_topic, post} = topic_with_post(author)
      payer = user("payer")
      key = Ecto.UUID.generate()

      TipPaymentServiceStub.unavailable()

      assert {:error, :payment_service_unavailable} =
               tip(post, payer, 1_000, idempotency_key: key)

      intent = Tips.get_intent_by_key(key)
      assert intent.state == "created"
      assert Tips.list_receipts(intent) == []
      assert Repo.reload!(post).tip_sats_total == 0

      TipPaymentServiceStub.settle()
      assert {:ok, settled} = tip(post, payer, 1_000, idempotency_key: key)
      assert settled.id == intent.id
      assert settled.state == "settled"
      assert Repo.reload!(post).tip_sats_counted == 1_000
    end

    test "a tip larger than the per-tip cap counts only up to the cap" do
      author = author()
      {_topic, post} = topic_with_post(author)

      assert {:ok, intent} = tip(post, user("payer"), Tips.counted_sats_per_tip() * 2)
      assert intent.counted_sats == Tips.counted_sats_per_tip()
      assert intent.amount_sats == Tips.counted_sats_per_tip() * 2
    end

    test "an amount past the maximum is refused" do
      author = author()
      {_topic, post} = topic_with_post(author)

      assert {:error, %Ecto.Changeset{}} =
               tip(post, user("payer"), Tips.maximum_amount_sats() + 1)
    end
  end

  describe "anti-manipulation" do
    test "a self-tip pays but does not improve rank" do
      author = author()
      {topic, post} = topic_with_post(author)

      assert {:ok, intent} = tip(post, author.user, 5_000)
      assert intent.state == "settled"
      assert intent.counted_sats == 0
      assert intent.exclusion_reason == "self_tip"

      assert Repo.reload!(post).tip_sats_total == 5_000
      assert Repo.reload!(post).tip_sats_counted == 0
      assert Repo.reload!(topic).tip_sats_counted == 0
    end

    test "tips that go in a circle stop counting" do
      first = author()
      second = author()
      {_first_topic, first_post} = topic_with_post(first)
      {_second_topic, second_post} = topic_with_post(second)

      assert {:ok, outbound} = tip(second_post, first.user, 2_000)
      assert outbound.counted_sats == 2_000

      assert {:ok, returned} = tip(first_post, second.user, 2_000)
      assert returned.counted_sats == 0
      assert returned.exclusion_reason == "reciprocal"
      assert Repo.reload!(first_post).tip_sats_counted == 0
    end

    test "one payer cannot exceed the per-post cap by splitting tips" do
      author = author()
      {_topic, post} = topic_with_post(author)
      payer = user("payer")

      assert {:ok, first} = tip(post, payer, Tips.counted_sats_per_tip())
      assert first.counted_sats == Tips.counted_sats_per_tip()

      assert {:ok, second} = tip(post, payer, 1_000)
      assert second.counted_sats == 0
      assert second.exclusion_reason == "payer_cap"

      assert Repo.reload!(post).tip_sats_counted == Tips.counted_sats_per_tip()
    end

    test "an automated burst of tips stops counting" do
      author = author()
      payer = user("payer")

      counted =
        Enum.map(1..22, fn index ->
          {_topic, post} = topic_with_post(author, "Topic #{index}")
          {:ok, intent} = tip(post, payer, 10)
          intent.counted_sats
        end)

      assert Enum.take(counted, 20) == List.duplicate(10, 20)
      assert Enum.drop(counted, 20) == [0, 0]

      assert Repo.all(from(i in TipIntent, where: i.exclusion_reason == "rate_limited"))
             |> length() == 2
    end
  end

  describe "refunds" do
    test "a refund removes ranking weight and keeps both receipts" do
      author = author()
      {topic, post} = topic_with_post(author)

      {:ok, intent} = tip(post, user("payer"), 3_000)
      assert {:ok, refunded} = Tips.refund(intent)

      assert refunded.state == "refunded"
      assert refunded.counted_sats == 0
      assert refunded.exclusion_reason == "refunded"

      assert Enum.map(Tips.list_receipts(refunded), & &1.kind) == ["settled", "refunded"]
      assert Repo.reload!(post).tip_sats_total == 0
      assert Repo.reload!(post).tip_sats_counted == 0
      assert Repo.reload!(post).tip_count == 0
      assert Repo.reload!(topic).tip_sats_counted == 0
    end

    test "only a settled tip can be refunded" do
      author = author()
      {_topic, post} = topic_with_post(author)
      TipPaymentServiceStub.fail("insufficient_balance")

      {:error, {:payment_failed, failed}} = tip(post, user("payer"), 100)

      assert {:error, {:not_refundable, "failed"}} = Tips.refund(failed)
    end

    test "a receipt cannot be rewritten or deleted" do
      author = author()
      {_topic, post} = topic_with_post(author)
      {:ok, intent} = tip(post, user("payer"), 100)
      [receipt] = Tips.list_receipts(intent)

      assert_raise Postgrex.Error, fn ->
        Repo.update_all(from(r in TipReceipt, where: r.id == ^receipt.id),
          set: [amount_sats: 1_000_000]
        )
      end
    end
  end

  describe "moderation" do
    test "hiding a post removes its tips from topic ranking without moving funds" do
      author = author()
      {topic, post} = topic_with_post(author)
      moderator = user("moderator")

      {:ok, intent} = tip(post, user("payer"), 4_000)
      assert Repo.reload!(topic).tip_sats_counted == 4_000

      {:ok, _hidden} = Forum.hide_post(Repo.reload!(post), moderator)

      assert Repo.reload!(topic).tip_sats_counted == 0
      assert Repo.reload!(post).tip_sats_total == 4_000
      assert Repo.reload!(intent).state == "settled"
      assert Enum.map(Tips.list_receipts(intent), & &1.kind) == ["settled"]
    end
  end

  describe "ranking" do
    test "a tipped topic ranks above an untipped one of the same age" do
      board = forum()
      author = author()

      {:ok, quiet} =
        Forum.create_topic(board, %{
          title: "Quiet",
          slug: "quiet",
          body_text: "Nothing here",
          actor_ref: author.actor_ref,
          actor_display_name: "Author",
          actor_slug: "author"
        })

      {:ok, tipped} =
        Forum.create_topic(board, %{
          title: "Tipped",
          slug: "tipped",
          body_text: "Worth sats",
          actor_ref: author.actor_ref,
          actor_display_name: "Author",
          actor_slug: "author"
        })

      [post] = Forum.list_posts(tipped)
      {:ok, _intent} = tip(post, user("payer"), 5_000)

      assert Enum.map(Forum.list_topics(board, order: :ranked), & &1.id) == [tipped.id, quiet.id]
      assert Enum.map(Forum.list_topics(board), & &1.id) == [tipped.id, quiet.id]
    end

    test "ranking keeps working when the payment service is unavailable" do
      board = forum()
      author = author()

      {:ok, tipped} =
        Forum.create_topic(board, %{
          title: "Tipped",
          slug: "tipped",
          body_text: "Worth sats",
          actor_ref: author.actor_ref,
          actor_display_name: "Author",
          actor_slug: "author"
        })

      [post] = Forum.list_posts(tipped)
      {:ok, _intent} = tip(post, user("payer"), 5_000)

      TipPaymentServiceStub.unavailable()

      assert Enum.map(Forum.list_topics(board, order: :ranked), & &1.id) == [tipped.id]
      assert {:error, :payment_service_unavailable} = tip(post, user("payer"), 100)
      assert Repo.reload!(tipped).tip_sats_counted == 5_000
    end

    test "a decayed tip ranks below a fresh tip of the same size" do
      board = forum()
      author = author()

      {:ok, old} =
        Forum.create_topic(board, %{
          title: "Old",
          slug: "old",
          body_text: "Tipped a month ago",
          actor_ref: author.actor_ref,
          actor_display_name: "Author",
          actor_slug: "author"
        })

      {:ok, fresh} =
        Forum.create_topic(board, %{
          title: "Fresh",
          slug: "fresh",
          body_text: "Tipped now",
          actor_ref: author.actor_ref,
          actor_display_name: "Author",
          actor_slug: "author"
        })

      for topic <- [old, fresh] do
        [post] = Forum.list_posts(topic)
        {:ok, _intent} = tip(post, user("payer"), 5_000)
      end

      month_ago = DateTime.add(DateTime.utc_now(), -30 * 24 * 3600, :second)

      Repo.update_all(from(t in OpenAgents.Forum.Topic, where: t.id == ^old.id),
        set: [updated_at: month_ago]
      )

      assert Enum.map(Forum.list_topics(board, order: :ranked), & &1.id) == [fresh.id, old.id]
    end
  end

  describe "recipient views" do
    test "the export lists settlements to verify and no destination" do
      author = author()
      {_topic, post} = topic_with_post(author)
      {:ok, intent} = tip(post, user("payer"), 700)

      export = Tips.withdrawal_export(author.user.id)

      assert export.custody == "self"
      assert export.received_sats == 700
      assert export.refunded_sats == 0
      assert [settlement] = export.settlements
      assert settlement.state == "settled"
      assert [%{payment_hash: hash}] = Tips.list_receipts(intent)
      assert settlement.payment_hash == hash

      destination = Tips.active_destination(author.user.id)
      assert export.destination_fingerprint == destination.fingerprint
      refute export.destination_fingerprint == destination.destination
    end

    test "a refund shows in the export as refunded" do
      author = author()
      {_topic, post} = topic_with_post(author)
      {:ok, intent} = tip(post, user("payer"), 700)
      {:ok, _refunded} = Tips.refund(intent)

      export = Tips.withdrawal_export(author.user.id)
      assert export.received_sats == 0
      assert export.refunded_sats == 700
    end
  end
end
