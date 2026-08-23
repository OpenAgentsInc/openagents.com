defmodule OpenAgents.Forge.Assignment do
  @moduledoc "A repository-scoped assignment of one issue to one Box."

  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(admitted running completed failed cancelled)
  @terminal_states ~w(completed failed cancelled)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "forge_assignments" do
    belongs_to :conversation_box, OpenAgents.Box.ConversationBox
    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :issue, OpenAgents.Issues.Issue, type: :id
    belongs_to :run, OpenAgents.Box.Run
    field :requesting_principal, :map
    field :branch, :string
    field :state, :string, default: "admitted"
    field :terminal_branch, :string
    field :terminal_commit, :string
    field :failure_reason, :string
    field :deadline_at, :utc_datetime_usec
    field :admitted_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    timestamps()
  end

  @type t :: %__MODULE__{}

  def states, do: @states
  def terminal_states, do: @terminal_states
  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :requesting_principal,
      :branch,
      :state,
      :terminal_branch,
      :terminal_commit,
      :failure_reason,
      :deadline_at,
      :admitted_at,
      :started_at,
      :finished_at,
      :run_id
    ])
    |> put_programmatic(attrs, :conversation_box_id)
    |> put_programmatic(attrs, :repository_id)
    |> put_programmatic(attrs, :issue_id)
    |> validate_required([
      :conversation_box_id,
      :repository_id,
      :issue_id,
      :requesting_principal,
      :branch,
      :deadline_at,
      :admitted_at
    ])
    |> validate_inclusion(:state, @states)
    |> validate_format(
      :branch,
      ~r/\A(?![.-])(?!.*(?:\.\.|@\{|[ ~^:?*\[\\]))[^\s:]+(?<!\.)(?<!\/)(?<!\.lock)\z/
    )
    |> foreign_key_constraint(:conversation_box_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:run_id)
    |> unique_constraint(:conversation_box_id, name: :forge_assignments_one_active_box_index)
    |> unique_constraint(:issue_id, name: :forge_assignments_one_active_issue_index)
  end

  defp put_programmatic(changeset, attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end
end
