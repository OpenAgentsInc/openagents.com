defmodule OpenAgents.ExperienceMemory.BankItem do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  schema "experience_bank_items" do
    belongs_to :bank, OpenAgents.ExperienceMemory.Bank
    belongs_to :record, OpenAgents.ExperienceMemory.Record
    belongs_to :pattern, OpenAgents.ExperienceMemory.Pattern
    field :kind, :string
    field :ordinal, :integer
    field :projection, :map
    field :projection_digest, :string
    timestamps()
  end

  def changeset(item, attrs),
    do:
      item
      |> cast(attrs, [
        :bank_id,
        :record_id,
        :pattern_id,
        :kind,
        :ordinal,
        :projection,
        :projection_digest
      ])
      |> validate_required([:bank_id, :kind, :ordinal, :projection, :projection_digest])
      |> validate_inclusion(:kind, ~w(record pattern))
      |> validate_format(:projection_digest, ~r/\A[0-9a-f]{64}\z/)
end
