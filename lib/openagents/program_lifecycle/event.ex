defmodule OpenAgents.ProgramLifecycle.Event do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "program_lifecycle_events" do
    field :artifact_id, :string
    field :signature_id, :string
    field :event_type, :string
    field :actor_type, :string
    field :actor_id, :string
    field :receipt, :map
    field :previous_artifact_id, :string
    timestamps()
  end

  def changeset(event, attributes) do
    event
    |> cast(attributes, [
      :artifact_id,
      :signature_id,
      :event_type,
      :actor_type,
      :actor_id,
      :receipt,
      :previous_artifact_id
    ])
    |> validate_required([
      :artifact_id,
      :signature_id,
      :event_type,
      :actor_type,
      :actor_id,
      :receipt
    ])
    |> validate_inclusion(:event_type, ~w(compiled evaluated approved activated rolled_back))
    |> validate_inclusion(:actor_type, ~w(compiler evaluator human))
  end
end
