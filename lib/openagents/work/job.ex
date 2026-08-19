defmodule OpenAgents.Work.Job do
  @moduledoc """
  One durable delegated deep-work job.

  A job is the RLM Phase 1 delegation unit: multi-step tool work moved out of a
  fragile response cycle into a budgeted, recoverable, server-side loop. Rows
  are append-only in discipline: identity fields never change, status moves
  only forward, and every terminal state carries a non-empty (possibly partial)
  report. PostgreSQL triggers enforce the transitions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued running completed failed interrupted budget_exhausted cancelled)
  @terminal_statuses ~w(completed failed interrupted budget_exhausted cancelled)
  @surfaces ~w(text voice)
  @kinds ~w(deep_work delegation coding)
  @maximum_goal_bytes 2_000
  @maximum_context_hint_bytes 2_000
  @maximum_report_bytes 8_000

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "work_jobs" do
    belongs_to :conversation, OpenAgents.Conversations.Conversation
    belongs_to :owner_visitor, OpenAgents.Conversations.Visitor
    field :surface, :string
    field :goal, :string
    field :context_hint, :string
    field :requesting_tool_step_ref, :string
    field :kind, :string, default: "deep_work"
    field :delegation, :map
    field :status, :string, default: "queued"
    field :report, :string
    field :error_code, :string
    field :model_id, :string
    field :instruction_digest, :string
    field :tool_catalog_digest, :string
    field :memory_snapshot_ref, :string
    field :tool_call_count, :integer, default: 0
    field :continuation_count, :integer, default: 0
    field :usage, :map
    field :owner_node, :string
    field :generation, :integer, default: 0
    belongs_to :report_message, OpenAgents.Conversations.Message
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps()
  end

  def statuses, do: @statuses
  def terminal_statuses, do: @terminal_statuses
  def maximum_goal_bytes, do: @maximum_goal_bytes
  def maximum_context_hint_bytes, do: @maximum_context_hint_bytes
  def maximum_report_bytes, do: @maximum_report_bytes

  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses

  @doc "Creates the immutable job identity. Programmatic IDs are set explicitly."
  def create_changeset(job, attributes) do
    job
    |> cast(attributes, [
      :surface,
      :goal,
      :context_hint,
      :requesting_tool_step_ref,
      :kind,
      :delegation
    ])
    |> put_change(:conversation_id, Map.fetch!(attributes, :conversation_id))
    |> put_change(:owner_visitor_id, Map.fetch!(attributes, :owner_visitor_id))
    |> validate_required([:conversation_id, :owner_visitor_id, :surface, :goal])
    |> validate_inclusion(:surface, @surfaces)
    |> validate_inclusion(:kind, @kinds)
    |> validate_byte_length(:goal, @maximum_goal_bytes)
    |> validate_byte_length(:context_hint, @maximum_context_hint_bytes)
    |> validate_length(:requesting_tool_step_ref, max: 256)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:owner_visitor_id)
  end

  @doc "Moves the job through its running lifecycle without touching identity."
  def lifecycle_changeset(job, attributes) do
    job
    |> cast(attributes, [
      :status,
      :report,
      :error_code,
      :model_id,
      :instruction_digest,
      :tool_catalog_digest,
      :memory_snapshot_ref,
      :tool_call_count,
      :continuation_count,
      :usage,
      :report_message_id,
      :owner_node,
      :generation,
      :started_at,
      :completed_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_byte_length(:report, @maximum_report_bytes)
    |> validate_terminal_report()
  end

  defp validate_terminal_report(changeset) do
    status = get_field(changeset, :status)
    report = get_field(changeset, :report)

    if status in @terminal_statuses and (is_nil(report) or report == "") do
      add_error(changeset, :report, "terminal work jobs must carry a non-empty report")
    else
      changeset
    end
  end

  defp validate_byte_length(changeset, field, maximum) do
    case get_field(changeset, field) do
      nil ->
        changeset

      value when is_binary(value) ->
        if byte_size(value) <= maximum,
          do: changeset,
          else: add_error(changeset, field, "exceeds #{maximum} bytes")

      _invalid ->
        changeset
    end
  end
end
