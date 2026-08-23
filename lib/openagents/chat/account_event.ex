defmodule OpenAgents.Chat.AccountEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  schema "account_chat_events" do
    belongs_to :run, OpenAgents.Chat.AccountRun
    field :sequence, :integer
    field :kind, :string
    field :payload, :map, default: %{}
    field :observed_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:sequence, :kind, :payload, :observed_at])
    |> validate_required([:run_id, :sequence, :kind, :payload, :observed_at])
    |> validate_number(:sequence, greater_than: 0)
    |> foreign_key_constraint(:run_id)
    |> unique_constraint([:run_id, :sequence])
  end
end
