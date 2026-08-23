defmodule OpenAgents.Box.Run do
  @moduledoc "One durable detached command run on a Box computer."

  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(admitted dispatched running completed failed cancelled timed_out lost)
  @terminal_states ~w(completed failed cancelled timed_out lost)
  @maximum_command_bytes 8_000
  @maximum_idempotency_key_bytes 256

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "box_runs" do
    belongs_to :conversation, OpenAgents.Conversations.Conversation
    belongs_to :conversation_box, OpenAgents.Box.ConversationBox
    field :requesting_principal, :map
    field :command, :string
    field :idempotency_key, :string
    field :state, :string, default: "admitted"
    field :exit_status, :integer
    field :timed_out, :boolean, default: false
    field :output, :string, default: ""
    field :output_base_offset, :integer, default: 0
    field :last_output_offset, :integer, default: 0
    field :pid, :integer
    field :run_directory, :string
    field :failure_reason, :string
    field :dispatch_attempted_at, :utc_datetime_usec
    field :probe_attempted_at, :utc_datetime_usec
    field :admitted_at, :utc_datetime_usec
    field :dispatched_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :cancellation_requested_at, :utc_datetime_usec
    field :cancellation_effective_at, :utc_datetime_usec
    field :deadline_at, :utc_datetime_usec
    timestamps()
  end

  @type t :: %__MODULE__{}

  @spec states() :: [String.t()]
  def states, do: @states

  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal_states

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states

  @spec maximum_command_bytes() :: pos_integer()
  def maximum_command_bytes, do: @maximum_command_bytes

  @spec maximum_idempotency_key_bytes() :: pos_integer()
  def maximum_idempotency_key_bytes, do: @maximum_idempotency_key_bytes

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attributes) do
    run
    |> cast(attributes, [
      :requesting_principal,
      :command,
      :idempotency_key,
      :state,
      :exit_status,
      :timed_out,
      :output,
      :output_base_offset,
      :last_output_offset,
      :pid,
      :run_directory,
      :failure_reason,
      :dispatch_attempted_at,
      :probe_attempted_at,
      :admitted_at,
      :dispatched_at,
      :started_at,
      :finished_at,
      :cancellation_requested_at,
      :cancellation_effective_at,
      :deadline_at
    ])
    |> put_programmatic(attributes, :conversation_id)
    |> put_programmatic(attributes, :conversation_box_id)
    |> validate_required([
      :conversation_id,
      :conversation_box_id,
      :requesting_principal,
      :command,
      :idempotency_key,
      :run_directory,
      :admitted_at,
      :deadline_at
    ])
    |> validate_inclusion(:state, @states)
    |> validate_length(:command, max: @maximum_command_bytes)
    |> validate_length(:idempotency_key, max: @maximum_idempotency_key_bytes)
    |> validate_number(:output_base_offset, greater_than_or_equal_to: 0)
    |> validate_number(:last_output_offset, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:conversation_box_id)
    |> unique_constraint(:idempotency_key)
    |> unique_constraint(:conversation_box_id, name: :box_runs_one_active_per_box_index)
  end

  defp put_programmatic(changeset, attributes, field) do
    case Map.fetch(attributes, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end
end
