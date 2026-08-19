defmodule OpenAgents.Conversations.Visitor do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "visitors" do
    field :browser_key_hash, :binary
    belongs_to :user, OpenAgents.Accounts.User
    has_one :conversation, OpenAgents.Conversations.Conversation
    has_one :profile_memory_scope, OpenAgents.ProfileMemory.Scope, foreign_key: :owner_visitor_id

    has_many :profile_memory_records, OpenAgents.ProfileMemory.Record,
      foreign_key: :owner_visitor_id

    has_many :profile_memory_snapshots, OpenAgents.ProfileMemory.SnapshotRecord,
      foreign_key: :owner_visitor_id

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          browser_key_hash: binary() | nil,
          user_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  def changeset(visitor, attributes) do
    visitor
    |> cast(attributes, [:browser_key_hash, :user_id])
    |> validate_identity_source()
    |> unique_constraint(:browser_key_hash)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:browser_key_hash, name: :visitors_identity_source_check)
  end

  defp validate_identity_source(changeset) do
    case {get_field(changeset, :browser_key_hash), get_field(changeset, :user_id)} do
      {browser_key_hash, nil} when is_binary(browser_key_hash) ->
        changeset

      {nil, user_id} when is_binary(user_id) ->
        changeset

      _invalid ->
        add_error(changeset, :user_id, "must identify exactly one account or legacy browser")
    end
  end
end
