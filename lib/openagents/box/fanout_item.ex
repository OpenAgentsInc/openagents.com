defmodule OpenAgents.Box.FanoutItem do
  @moduledoc "One logical Box in a fan-out admission plan."

  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(admitted queued refused)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "box_fanout_items" do
    belongs_to :request, OpenAgents.Box.FanoutRequest
    belongs_to :conversation, OpenAgents.Conversations.Conversation
    belongs_to :conversation_box, OpenAgents.Box.ConversationBox
    field :requesting_principal, :map
    field :position, :integer
    field :queue_sequence, :integer
    field :label, :string
    field :state, :string, default: "queued"
    field :queue_reason, :string
    field :estimated_burn_rate_microusd, :integer
    field :admitted_at, :utc_datetime_usec
    field :queued_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @spec states() :: [String.t()]
  def states, do: @states

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :position,
      :label,
      :requesting_principal,
      :state,
      :queue_reason,
      :estimated_burn_rate_microusd,
      :admitted_at
    ])
    |> put_programmatic(:request_id, attrs)
    |> put_programmatic(:conversation_id, attrs)
    |> put_programmatic(:conversation_box_id, attrs)
    |> put_change(:queued_at, Map.get(attrs, :queued_at, DateTime.utc_now()))
    |> validate_required([
      :request_id,
      :conversation_id,
      :requesting_principal,
      :position,
      :label,
      :state,
      :estimated_burn_rate_microusd,
      :queued_at
    ])
    |> validate_inclusion(:state, @states)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:estimated_burn_rate_microusd, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:request_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:conversation_box_id)
    |> unique_constraint(:label, name: :box_fanout_items_active_label_index)
  end

  defp put_programmatic(changeset, field, attrs) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end
end
