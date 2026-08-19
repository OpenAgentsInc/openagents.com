defmodule OpenAgents.Memory.PolicyEvent do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "profile_memory_policy_events" do
    belongs_to :owner_visitor, OpenAgents.Conversations.Visitor
    field :policy_version, :string
    field :outcome, :string
    field :reason_code, :string
    field :category, :string
    field :input_size_bucket, :string
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(event, attributes) do
    event
    |> cast(attributes, [
      :policy_version,
      :outcome,
      :reason_code,
      :category,
      :input_size_bucket,
      :inserted_at
    ])
    |> validate_required([
      :owner_visitor_id,
      :policy_version,
      :outcome,
      :reason_code,
      :category,
      :input_size_bucket,
      :inserted_at
    ])
    |> foreign_key_constraint(:owner_visitor_id)
  end
end
