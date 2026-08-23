defmodule OpenAgents.Box.FanoutRequest do
  @moduledoc "One durable multi-box admission plan."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "box_fanout_requests" do
    belongs_to :conversation, OpenAgents.Conversations.Conversation
    has_many :items, OpenAgents.Box.FanoutItem, foreign_key: :request_id
    field :requesting_principal, :map
    field :requested_count, :integer
    field :budgeted, :boolean, default: false
    field :effective_limits, :map
    field :state, :string, default: "admitted"
    field :admitted_count, :integer, default: 0
    field :queued_count, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :requesting_principal,
      :requested_count,
      :budgeted,
      :effective_limits,
      :state,
      :admitted_count,
      :queued_count
    ])
    |> put_programmatic(:conversation_id, attrs)
    |> validate_required([
      :conversation_id,
      :requesting_principal,
      :requested_count,
      :effective_limits
    ])
    |> validate_number(:requested_count, greater_than: 0)
    |> validate_number(:admitted_count, greater_than_or_equal_to: 0)
    |> validate_number(:queued_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:conversation_id)
  end

  defp put_programmatic(changeset, field, attrs) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end
end
