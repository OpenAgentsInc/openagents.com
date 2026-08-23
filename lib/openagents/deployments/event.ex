defmodule OpenAgents.Deployments.Event do
  @moduledoc """
  One append-only record of something that happened to a run.

  Events carry a per-run monotonic `sequence`, so a reader can poll or stream
  from a cursor and know it missed nothing. The table has no update timestamp
  because nothing rewrites a transition after it commits; a correction is a new
  event.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias OpenAgents.Deployments.Run

  @actor_types ~w(user workflow operator system provider)
  @maximum_detail_bytes 4_096

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "deployment_events" do
    field :sequence, :integer
    field :type, :string
    field :from_state, :string
    field :to_state, :string
    field :detail, :map, default: %{}
    field :actor_type, :string
    field :actor_id, :string
    field :occurred_at, :utc_datetime_usec

    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :deployment_run, OpenAgents.Deployments.Run

    timestamps()
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:sequence, :type, :from_state, :to_state, :detail, :actor_type, :actor_id])
    |> validate_required([:sequence, :type, :detail, :actor_type])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_length(:type, min: 1, max: 60)
    |> validate_inclusion(:actor_type, @actor_types)
    |> validate_length(:actor_id, max: 64)
    |> validate_state(:from_state)
    |> validate_state(:to_state)
    |> validate_detail()
    |> put_change(:occurred_at, DateTime.utc_now())
    |> unique_constraint(:sequence, name: :deployment_events_deployment_run_id_sequence_index)
  end

  @doc "The actor kinds an event can attribute a transition to."
  @spec actor_types() :: [String.t()]
  def actor_types, do: @actor_types

  defp validate_state(changeset, field),
    do: validate_inclusion(changeset, field, Run.states())

  # Event detail reaches tenant reads, webhooks, and audit exports, so it is
  # bounded here rather than trusted from the caller.
  defp validate_detail(changeset) do
    validate_change(changeset, :detail, fn :detail, detail ->
      encoded = Jason.encode_to_iodata!(detail)

      if IO.iodata_length(encoded) > @maximum_detail_bytes do
        [detail: "exceeds #{@maximum_detail_bytes} bytes"]
      else
        []
      end
    end)
  end
end
