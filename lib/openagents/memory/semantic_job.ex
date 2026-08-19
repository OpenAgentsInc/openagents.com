defmodule OpenAgents.Memory.SemanticJob do
  @moduledoc "Idempotent asynchronous embedding outbox row for one authoritative message."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "semantic_embedding_jobs" do
    belongs_to :message, OpenAgents.Conversations.Message
    belongs_to :conversation, OpenAgents.Conversations.Conversation
    belongs_to :manifest, OpenAgents.Memory.SemanticManifest
    field :generation, :integer
    field :model_id, :string
    field :model_version, :string
    field :dimensions, :integer
    field :content_digest, :string
    field :status, :string
    field :attempts, :integer
    field :error_code, :string
    field :available_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps()
  end

  def lifecycle_changeset(record, attributes) do
    record
    |> cast(
      attributes,
      ~w(status attempts error_code available_at started_at completed_at content_digest)a
    )
    |> validate_inclusion(:status, ~w(pending running completed failed invalidated))
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_format(:content_digest, ~r/\A[0-9a-f]{64}\z/)
  end
end
