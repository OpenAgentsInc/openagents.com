defmodule OpenAgents.Forum.TipIntent do
  @moduledoc """
  One account's intent to send sats to one post.

  An intent carries the payment's own state and, separately, the `counted_sats`
  that ranking may use. The tipping policy sets `counted_sats` once, at
  settlement; a refund returns it to zero. A paid tip that ranking must ignore
  is therefore still a complete payment record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.Forum.{Post, TipDestination, Topic}

  @states ["created", "settled", "failed", "refunded"]
  @exclusion_reasons ["self_tip", "reciprocal", "payer_cap", "rate_limited", "refunded"]
  @maximum_amount_sats 1_000_000

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "forum_tip_intents" do
    field :idempotency_key, :string
    field :amount_sats, :integer
    field :counted_sats, :integer, default: 0
    field :exclusion_reason, :string

    field :payer_actor_ref, :string
    field :state, :string, default: "created"
    field :failure_code, :string
    field :settled_at, :utc_datetime_usec
    field :failed_at, :utc_datetime_usec
    field :refunded_at, :utc_datetime_usec

    belongs_to :post, Post, type: :binary_id
    belongs_to :topic, Topic, type: :binary_id
    belongs_to :payer_user, User, type: :binary_id
    belongs_to :recipient_user, User, type: :binary_id
    belongs_to :destination, TipDestination, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  def maximum_amount_sats, do: @maximum_amount_sats

  def exclusion_reasons, do: @exclusion_reasons

  def changeset(intent, attrs) do
    intent
    |> cast(attrs, [
      :idempotency_key,
      :amount_sats,
      :payer_actor_ref,
      :state,
      :counted_sats,
      :exclusion_reason
    ])
    |> validate_required([:idempotency_key, :amount_sats, :payer_actor_ref])
    |> validate_number(:amount_sats,
      greater_than: 0,
      less_than_or_equal_to: @maximum_amount_sats
    )
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:exclusion_reason, @exclusion_reasons)
    |> unique_constraint(:idempotency_key)
    |> check_constraint(:amount_sats, name: :forum_tip_intents_amount_check)
  end
end
