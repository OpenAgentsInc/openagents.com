defmodule OpenAgents.Forum.Tips do
  @moduledoc """
  Self-custodial Bitcoin tips on forum posts.

  Three facts stay separate here:

  1. **Where sats go** — a destination the recipient supplied and controls.
     The forum stores an offer, address, or Lightning address, never a key,
     seed, channel, or node credential, so it cannot hold or spend a tip.
  2. **What a payment did** — an intent plus an append-only receipt. A tip's
     `idempotency_key` is unique, so a retry returns the first result instead
     of paying twice.
  3. **What ranking may use** — `counted_sats`, set once at settlement by the
     policy in this module and returned to zero by a refund. A self-tip, a
     reciprocal tip, a tip past a payer's cap, and a burst of automated tips
     all settle normally and count nothing.

  Ranking reads only stored settlement facts, so an unavailable payment
  service stops new tips and changes nothing about what is already ranked.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias OpenAgents.Forum
  alias OpenAgents.Forum.{Post, TipDestination, TipIntent, TipReceipt, Topic}
  alias OpenAgents.Forum.Tips.PaymentService
  alias OpenAgents.Repo

  # A single tip can carry at most this much ranking weight, however large the
  # payment. Sats buy attention with diminishing returns, not a ranking bypass.
  @counted_sats_per_tip 25_000

  # And one payer can carry at most this much weight on one post, across tips.
  @counted_sats_per_payer_post 25_000

  # More settled tips than this from one payer within the window reads as
  # automation rather than judgment, so the excess counts nothing.
  @payer_burst_limit 20
  @payer_burst_window_seconds 3600

  # Two accounts tipping each other inside this window is treated as circular,
  # so the return tip carries no weight.
  @reciprocal_window_seconds 30 * 24 * 3600

  def counted_sats_per_tip, do: @counted_sats_per_tip
  def maximum_amount_sats, do: TipIntent.maximum_amount_sats()

  ## Destinations

  @doc "The destination an account currently receives tips at, if any."
  @spec active_destination(binary() | nil) :: TipDestination.t() | nil
  def active_destination(nil), do: nil

  def active_destination(user_id) when is_binary(user_id) do
    Repo.one(
      from d in TipDestination,
        where: d.user_id == ^user_id and d.state == "active",
        limit: 1
    )
  end

  @doc """
  Records where an account wants tips to arrive.

  Registering a new destination retires the previous one in the same
  transaction, so an account always has at most one active destination and the
  history of what it was stays intact.
  """
  @spec register_destination(map()) ::
          {:ok, TipDestination.t()} | {:error, Ecto.Changeset.t()}
  def register_destination(attrs) when is_map(attrs) do
    user_id = attrs[:user_id] || attrs["user_id"]

    Multi.new()
    |> Multi.run(:retire_previous, fn _repo, _changes ->
      case active_destination(user_id) do
        nil -> {:ok, nil}
        current -> retire_destination(current)
      end
    end)
    |> Multi.insert(:destination, TipDestination.changeset(%TipDestination{}, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{destination: destination}} -> {:ok, destination}
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
    end
  end

  @doc "Stops using a destination without touching the tips it already received."
  @spec retire_destination(TipDestination.t()) ::
          {:ok, TipDestination.t()} | {:error, Ecto.Changeset.t()}
  def retire_destination(%TipDestination{} = destination) do
    destination
    |> TipDestination.changeset(%{
      state: "retired",
      accepting_tips: false,
      retired_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @doc "Opts an account in or out of receiving tips, keeping its destination."
  @spec set_accepting_tips(TipDestination.t(), boolean()) ::
          {:ok, TipDestination.t()} | {:error, Ecto.Changeset.t()}
  def set_accepting_tips(%TipDestination{} = destination, accepting?)
      when is_boolean(accepting?) do
    destination
    |> TipDestination.changeset(%{accepting_tips: accepting?})
    |> Repo.update()
  end

  @doc """
  Whether a post can currently be tipped, and why not when it cannot.
  """
  @spec tip_availability(Post.t()) ::
          {:ok, TipDestination.t()}
          | {:error,
             :tipping_disabled | :post_not_visible | :no_destination | :not_accepting_tips}
  def tip_availability(%Post{} = post) do
    cond do
      not PaymentService.enabled?() ->
        {:error, :tipping_disabled}

      post.state != "visible" ->
        {:error, :post_not_visible}

      true ->
        case recipient_destination(post) do
          nil -> {:error, :no_destination}
          %TipDestination{accepting_tips: false} -> {:error, :not_accepting_tips}
          %TipDestination{} = destination -> {:ok, destination}
        end
    end
  end

  defp recipient_destination(%Post{} = post) do
    case Forum.actor_user(post.actor_ref) do
      nil -> nil
      user -> active_destination(user.id)
    end
  end

  ## Tips

  @doc """
  Sends sats from one account to the author of a post.

  The call is idempotent on `idempotency_key`: a retry returns the intent that
  already exists, so a repeated request cannot pay twice or count twice. When
  the payment service is unreachable the intent stays `created` and the same
  key can retry it later.
  """
  @spec tip_post(map()) ::
          {:ok, TipIntent.t()}
          | {:error,
             :tipping_disabled
             | :post_not_visible
             | :no_destination
             | :not_accepting_tips
             | :payment_service_unavailable
             | Ecto.Changeset.t()}
  def tip_post(%{
        post: %Post{} = post,
        payer_user: payer_user,
        payer_actor_ref: payer_actor_ref,
        amount_sats: amount_sats,
        idempotency_key: idempotency_key
      })
      when is_binary(payer_actor_ref) and is_binary(idempotency_key) do
    case get_intent_by_key(idempotency_key) do
      %TipIntent{} = existing ->
        resume(existing)

      nil ->
        with {:ok, destination} <- tip_availability(post),
             {:ok, intent} <-
               create_intent(post, payer_user, payer_actor_ref, amount_sats, destination,
                 idempotency_key: idempotency_key
               ) do
          pay(intent, destination)
        end
    end
  end

  @doc "One tip by its idempotency key."
  @spec get_intent_by_key(String.t()) :: TipIntent.t() | nil
  def get_intent_by_key(idempotency_key) when is_binary(idempotency_key),
    do: Repo.get_by(TipIntent, idempotency_key: idempotency_key)

  @doc "The receipts recorded for one tip, oldest first."
  @spec list_receipts(TipIntent.t()) :: [TipReceipt.t()]
  def list_receipts(%TipIntent{id: intent_id}) do
    Repo.all(
      from r in TipReceipt, where: r.intent_id == ^intent_id, order_by: [asc: r.occurred_at]
    )
  end

  # A retry never re-pays a tip that already reached a terminal state.
  defp resume(%TipIntent{state: "created"} = intent) do
    destination = Repo.get!(TipDestination, intent.destination_id)

    if destination.state == "active" and destination.accepting_tips do
      pay(intent, destination)
    else
      {:error, :not_accepting_tips}
    end
  end

  defp resume(%TipIntent{} = intent), do: {:ok, intent}

  defp create_intent(post, payer_user, payer_actor_ref, amount_sats, destination, opts) do
    recipient_user = Forum.actor_user(post.actor_ref)

    %TipIntent{
      post_id: post.id,
      topic_id: post.topic_id,
      payer_user_id: payer_user.id,
      recipient_user_id: recipient_user.id,
      destination_id: destination.id
    }
    |> TipIntent.changeset(%{
      idempotency_key: opts[:idempotency_key],
      payer_actor_ref: payer_actor_ref,
      amount_sats: amount_sats,
      state: "created"
    })
    |> Repo.insert()
    |> case do
      {:ok, intent} ->
        {:ok, intent}

      {:error, changeset} ->
        # Two concurrent retries: whichever lost the unique index reads the row.
        case get_intent_by_key(opts[:idempotency_key]) do
          %TipIntent{} = existing -> {:ok, existing}
          nil -> {:error, changeset}
        end
    end
  end

  defp pay(%TipIntent{} = intent, %TipDestination{} = destination) do
    request = %{
      kind: destination.kind,
      destination: destination.destination,
      amount_sats: intent.amount_sats,
      idempotency_key: intent.idempotency_key
    }

    case PaymentService.pay(request) do
      {:ok, settlement} -> settle(intent, settlement)
      {:error, {:payment_failed, failure_code}} -> fail(intent, failure_code)
      {:error, :payment_service_unavailable} -> {:error, :payment_service_unavailable}
    end
  end

  ## Payment state

  @doc """
  Records a settled payment and the ranking weight it earned.

  The receipt is written once per intent, so a duplicate settlement leaves both
  the receipt and the post totals alone.
  """
  @spec settle(TipIntent.t(), map()) :: {:ok, TipIntent.t()} | {:error, term()}
  def settle(%TipIntent{state: "created"} = intent, settlement) do
    settled_at = Map.get(settlement, :settled_at) || DateTime.utc_now()
    counted = counted_sats(intent, settled_at)

    Multi.new()
    |> Multi.insert(
      :receipt,
      TipReceipt.changeset(%TipReceipt{}, %{
        intent_id: intent.id,
        kind: "settled",
        amount_sats: intent.amount_sats,
        fee_sats: Map.get(settlement, :fee_sats, 0),
        payment_hash: Map.get(settlement, :payment_hash),
        occurred_at: settled_at
      })
    )
    |> Multi.update(
      :intent,
      TipIntent.changeset(intent, %{
        state: "settled",
        counted_sats: counted.sats,
        exclusion_reason: counted.exclusion_reason
      })
      |> Ecto.Changeset.put_change(:settled_at, settled_at)
    )
    |> add_totals(intent, intent.amount_sats, counted.sats, 1)
    |> Repo.transaction()
    |> case do
      {:ok, %{intent: settled}} -> {:ok, settled}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def settle(%TipIntent{} = intent, _settlement), do: {:ok, intent}

  @doc "Records a payment that did not go through. A failed tip counts nothing."
  @spec fail(TipIntent.t(), String.t()) ::
          {:error, {:payment_failed, TipIntent.t()}} | {:error, term()}
  def fail(%TipIntent{state: "created"} = intent, failure_code) when is_binary(failure_code) do
    failed_at = DateTime.utc_now()

    Multi.new()
    |> Multi.insert(
      :receipt,
      TipReceipt.changeset(%TipReceipt{}, %{
        intent_id: intent.id,
        kind: "failed",
        amount_sats: intent.amount_sats,
        failure_code: failure_code,
        occurred_at: failed_at
      })
    )
    |> Multi.update(
      :intent,
      TipIntent.changeset(intent, %{state: "failed"})
      |> Ecto.Changeset.put_change(:failure_code, failure_code)
      |> Ecto.Changeset.put_change(:failed_at, failed_at)
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{intent: failed}} -> {:error, {:payment_failed, failed}}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def fail(%TipIntent{} = intent, _failure_code), do: {:error, {:payment_failed, intent}}

  @doc """
  Records a refund and removes the tip's ranking weight.

  The settled receipt stays; a refund appends its own. Totals lose both the
  gross amount and whatever weight the tip carried.
  """
  @spec refund(TipIntent.t(), String.t()) :: {:ok, TipIntent.t()} | {:error, term()}
  def refund(intent, failure_code \\ "refunded")

  def refund(%TipIntent{state: "settled"} = intent, failure_code) do
    refunded_at = DateTime.utc_now()

    Multi.new()
    |> Multi.insert(
      :receipt,
      TipReceipt.changeset(%TipReceipt{}, %{
        intent_id: intent.id,
        kind: "refunded",
        amount_sats: intent.amount_sats,
        failure_code: failure_code,
        occurred_at: refunded_at
      })
    )
    |> Multi.update(
      :intent,
      TipIntent.changeset(intent, %{
        state: "refunded",
        counted_sats: 0,
        exclusion_reason: "refunded"
      })
      |> Ecto.Changeset.put_change(:refunded_at, refunded_at)
    )
    |> add_totals(intent, -intent.amount_sats, -intent.counted_sats, -1)
    |> Repo.transaction()
    |> case do
      {:ok, %{intent: refunded}} -> {:ok, refunded}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def refund(%TipIntent{state: state}, _failure_code), do: {:error, {:not_refundable, state}}

  ## Ranking weight

  # How much ranking weight a settled tip earns. Everything that makes a tip
  # unusable as a signal is decided here, once, and recorded on the intent.
  defp counted_sats(%TipIntent{} = intent, settled_at) do
    cond do
      intent.payer_user_id == intent.recipient_user_id ->
        %{sats: 0, exclusion_reason: "self_tip"}

      reciprocal?(intent, settled_at) ->
        %{sats: 0, exclusion_reason: "reciprocal"}

      payer_burst?(intent, settled_at) ->
        %{sats: 0, exclusion_reason: "rate_limited"}

      true ->
        headroom = payer_post_headroom(intent)
        sats = Enum.min([intent.amount_sats, @counted_sats_per_tip, headroom])

        if sats > 0 do
          %{sats: sats, exclusion_reason: nil}
        else
          %{sats: 0, exclusion_reason: "payer_cap"}
        end
    end
  end

  # The recipient already paid this payer recently, so the sats went in a
  # circle and say nothing about the post.
  defp reciprocal?(%TipIntent{} = intent, settled_at) do
    since = DateTime.add(settled_at, -@reciprocal_window_seconds, :second)

    Repo.exists?(
      from i in TipIntent,
        where:
          i.payer_user_id == ^intent.recipient_user_id and
            i.recipient_user_id == ^intent.payer_user_id and
            i.state == "settled" and i.settled_at >= ^since
    )
  end

  defp payer_burst?(%TipIntent{} = intent, settled_at) do
    since = DateTime.add(settled_at, -@payer_burst_window_seconds, :second)

    recent =
      Repo.one!(
        from i in TipIntent,
          select: count(),
          where:
            i.payer_user_id == ^intent.payer_user_id and i.state == "settled" and
              i.settled_at >= ^since
      )

    recent >= @payer_burst_limit
  end

  defp payer_post_headroom(%TipIntent{} = intent) do
    counted =
      Repo.one!(
        from i in TipIntent,
          select: type(coalesce(sum(i.counted_sats), 0), :integer),
          where:
            i.post_id == ^intent.post_id and i.payer_user_id == ^intent.payer_user_id and
              i.state == "settled" and i.id != ^intent.id
      )

    max(@counted_sats_per_payer_post - counted, 0)
  end

  defp add_totals(multi, %TipIntent{} = intent, amount_sats, counted_sats, count) do
    multi
    |> Multi.update_all(
      :post_totals,
      fn _changes ->
        from p in Post, where: p.id == ^intent.post_id
      end,
      inc: [
        tip_sats_total: amount_sats,
        tip_sats_counted: counted_sats,
        tip_count: count
      ]
    )
    |> Multi.update_all(
      :topic_totals,
      fn _changes ->
        from t in Topic, where: t.id == ^intent.topic_id
      end,
      inc: [
        tip_sats_total: amount_sats,
        tip_sats_counted: counted_sats,
        tip_count: count
      ]
    )
  end

  @doc """
  Removes a post's ranking weight from its topic after moderation.

  A hidden or deleted post keeps its own totals, so nothing about the payments
  is rewritten, but its sats stop lifting the topic. Moderators need no access
  to funds to do this.
  """
  @spec withdraw_post_weight(Post.t()) :: :ok
  def withdraw_post_weight(%Post{} = post) do
    if post.tip_sats_counted > 0 do
      Repo.update_all(
        from(t in Topic, where: t.id == ^post.topic_id),
        inc: [tip_sats_counted: -post.tip_sats_counted]
      )
    end

    :ok
  end

  ## Recipient views

  @doc """
  What one account received, as the receipts a recipient can check.

  Each entry carries the payment hash from the settled receipt, which is what
  the recipient looks up in their own wallet to confirm the sats arrived.
  """
  @spec list_received(binary(), keyword()) :: [map()]
  def list_received(user_id, opts \\ []) when is_binary(user_id) do
    limit = min(Keyword.get(opts, :limit, 100), 500)

    Repo.all(
      from i in TipIntent,
        left_join: r in TipReceipt,
        on: r.intent_id == i.id and r.kind == "settled",
        where: i.recipient_user_id == ^user_id and i.state in ["settled", "refunded"],
        order_by: [desc: i.settled_at],
        limit: ^limit,
        select: %{
          intent_id: i.id,
          post_id: i.post_id,
          topic_id: i.topic_id,
          amount_sats: i.amount_sats,
          counted_sats: i.counted_sats,
          state: i.state,
          settled_at: i.settled_at,
          refunded_at: i.refunded_at,
          payment_hash: r.payment_hash,
          fee_sats: r.fee_sats
        }
    )
  end

  @doc """
  The totals an account received, for a self-custodial withdrawal.

  The forum holds nothing to withdraw. The export tells a recipient which
  settlements to expect in the wallet they control, and at which destination
  fingerprint they arrived.
  """
  @spec withdrawal_export(binary()) :: map()
  def withdrawal_export(user_id) when is_binary(user_id) do
    settled = list_received(user_id, limit: 500)

    received_sats =
      settled
      |> Enum.filter(&(&1.state == "settled"))
      |> Enum.map(& &1.amount_sats)
      |> Enum.sum()

    refunded_sats =
      settled
      |> Enum.filter(&(&1.state == "refunded"))
      |> Enum.map(& &1.amount_sats)
      |> Enum.sum()

    %{
      custody: "self",
      destination_fingerprint:
        case active_destination(user_id) do
          nil -> nil
          destination -> destination.fingerprint
        end,
      received_sats: received_sats,
      refunded_sats: refunded_sats,
      settlements:
        Enum.map(settled, fn entry ->
          %{
            post_id: entry.post_id,
            amount_sats: entry.amount_sats,
            state: entry.state,
            payment_hash: entry.payment_hash,
            settled_at: entry.settled_at
          }
        end)
    }
  end
end
