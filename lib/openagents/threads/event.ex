defmodule OpenAgents.Threads.Event do
  @moduledoc """
  One bounded, append-only entry in a thread's transcript
  (`openagents.thread.event.v1`).

  The schema string is pinned by the database and there is no `updated_at`, so a
  recorded event is evidence rather than state.

  Unlike `OpenAgents.SCV.ExecutionEvent`, whose payloads are a deliberately
  minimal projection of work that lives elsewhere, this table is the work: a
  thread's transcript has to reproduce the session as a full ATIF trajectory.
  So the payload carries what happened rather than a summary of it, and the only
  floor is that it is a JSON object — an event whose type is the whole of it
  satisfies that. What a client sends to a model is bounded by the client; what
  the record holds is what happened.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Threads.Thread

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @schema_version "openagents.thread.event.v1"

  schema "thread_events" do
    belongs_to :thread, Thread, type: :binary_id
    field :schema, :string, default: @schema_version
    field :event_type, :string
    field :payload, :map
    field :emitted_at, :utc_datetime_usec
    timestamps()
  end

  @type t :: %__MODULE__{}

  def schema_version, do: @schema_version

  @doc false
  def changeset(event, attributes) do
    event
    |> cast(attributes, [:thread_id, :schema, :event_type, :payload, :emitted_at])
    |> validate_required([:thread_id, :schema, :event_type, :payload, :emitted_at])
    |> validate_length(:event_type, min: 1, max: 80)
    |> validate_inclusion(:schema, [@schema_version])
    |> foreign_key_constraint(:thread_id)
    |> check_constraint(:schema, name: :thread_events_schema_check)
    |> check_constraint(:payload, name: :thread_events_payload_present_check)
  end
end
