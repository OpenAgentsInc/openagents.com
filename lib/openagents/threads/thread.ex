defmodule OpenAgents.Threads.Thread do
  @moduledoc """
  A thread: one objective, its turns, its transcript, and its budget
  (`docs/taxonomy.md`).

  A thread is account-scoped, plural, and disposable. It belongs to the
  account's owner visitor, never to a conversation — the account has exactly
  one conversation (DATA-002), and a thread is not one. Nothing on this record
  requires a conversation to exist.

  The columns follow `OpenAgents.SCV.Execution`, which is the durable
  execution record this repository already has with no conversation: a bounded
  objective, the admitted execution shape, a status ladder, a monotonic
  generation, a terminal report with its digest, and a metering map. The
  generation is the authority fence — see `OpenAgents.Threads.mint_grant/1`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Threads.Event

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(open succeeded failed cancelled)
  @terminal_statuses ~w(succeeded failed cancelled)
  @permission_profiles ~w(read_only workspace_write)
  @reasoning_efforts ~w(none minimal low medium high max)
  @objective_bytes 32_768
  @repository_bytes 200

  schema "threads" do
    belongs_to :owner_visitor, Visitor
    field :objective, :string, redact: true
    field :repository, :string
    field :status, :string, default: "open"
    field :model, :string
    field :reasoning_effort, :string
    field :permission_profile, :string, default: "read_only"
    field :generation, :integer, default: 0
    field :report, :string, redact: true
    field :report_digest, :string
    field :error_code, :string
    field :event_count, :integer, default: 0
    field :usage, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    has_many :events, Event, foreign_key: :thread_id
    timestamps()
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses
  def terminal_statuses, do: @terminal_statuses
  def permission_profiles, do: @permission_profiles
  def reasoning_efforts, do: @reasoning_efforts

  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{status: "open"}), do: true
  def open?(%__MODULE__{}), do: false

  @doc """
  The immutable capture at open time. `owner_visitor_id`, `status`,
  `generation`, and `started_at` are set by the context, never cast from a
  caller.

  `repository` is optional and deliberately unvalidated against the forge's
  repository table: a thread may concern a repository the forge does not host,
  so the field records the opener's `owner/name` string, bounded, with no
  foreign key and no format rule beyond non-blank.
  """
  def open_changeset(attributes, owner_visitor_id, now) do
    %__MODULE__{}
    |> cast(attributes, [:objective, :model, :reasoning_effort, :permission_profile, :repository])
    |> put_change(:owner_visitor_id, owner_visitor_id)
    |> put_change(:status, "open")
    |> put_change(:generation, 0)
    |> put_change(:started_at, now)
    |> validate_required([:objective, :model, :reasoning_effort, :permission_profile])
    |> validate_length(:objective, min: 1, max: @objective_bytes, count: :bytes)
    |> validate_length(:model, min: 1, max: 200)
    |> validate_length(:repository, min: 1, max: @repository_bytes, count: :bytes)
    |> validate_inclusion(:reasoning_effort, @reasoning_efforts)
    |> validate_inclusion(:permission_profile, @permission_profiles)
    |> foreign_key_constraint(:owner_visitor_id)
    |> check_constraint(:status, name: :threads_status_check)
    |> check_constraint(:objective, name: :threads_objective_bound_check)
    |> check_constraint(:repository, name: :threads_repository_bound_check)
    |> check_constraint(:reasoning_effort, name: :threads_reasoning_effort_check)
    |> check_constraint(:permission_profile, name: :threads_permission_profile_check)
  end

  @doc "Bump the authority fence. Every mint advances it; nothing lowers it."
  def generation_changeset(%__MODULE__{} = thread) do
    thread
    |> change(%{generation: thread.generation + 1})
    |> check_constraint(:generation, name: :threads_generation_nonnegative_check)
  end

  @doc "Advance the retained event counter alongside an appended event."
  def event_count_changeset(%__MODULE__{} = thread, count) do
    thread
    |> change(%{event_count: count})
    |> check_constraint(:event_count, name: :threads_event_count_nonnegative_check)
  end

  @doc "The terminal receipt. A thread ends once and carries a report when it does."
  def terminal_changeset(%__MODULE__{} = thread, attributes) do
    thread
    |> cast(attributes, [:status, :report, :report_digest, :usage, :error_code, :completed_at])
    |> validate_required([:status, :report, :report_digest, :completed_at])
    |> validate_inclusion(:status, @terminal_statuses)
    |> validate_length(:report, min: 1, max: @objective_bytes, count: :bytes)
    |> validate_format(:report_digest, ~r/\Asha256:[0-9a-f]{64}\z/)
    |> validate_length(:error_code, max: 80)
    |> check_constraint(:status, name: :threads_status_check)
    |> check_constraint(:report, name: :threads_report_bound_check)
    |> check_constraint(:completed_at, name: :threads_terminal_shape_check)
  end
end
