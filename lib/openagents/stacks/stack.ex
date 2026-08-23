defmodule OpenAgents.Stacks.Stack do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(open completed dissolved)
  @healths ~w(healthy needs_rebase conflicted missing_ref head_changed policy_blocked operation_in_progress)

  schema "pull_request_stacks" do
    belongs_to :repository, OpenAgents.Repositories.Repository
    field :number, :integer
    field :trunk_ref, :string
    field :state, :string, default: "open"
    field :health, :string, default: "healthy"
    field :version, :integer, default: 1
    belongs_to :created_by_user, OpenAgents.Accounts.User

    has_many :entries, OpenAgents.Stacks.StackEntry,
      foreign_key: :stack_id,
      preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states
  def healths, do: @healths

  def changeset(stack, attrs) do
    stack
    |> cast(attrs, [:number, :trunk_ref, :state, :health, :version])
    |> put_programmatic_change(attrs, :repository_id)
    |> put_programmatic_change(attrs, :created_by_user_id)
    |> validate_required([:repository_id, :number, :trunk_ref, :state, :health, :version])
    |> validate_length(:trunk_ref, min: 1, max: 255)
    |> validate_number(:number, greater_than_or_equal_to: 1)
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:health, @healths)
    |> unique_constraint([:repository_id, :number])
    |> check_constraint(:state, name: :pull_request_stacks_state_check)
    |> check_constraint(:health, name: :pull_request_stacks_health_check)
    |> check_constraint(:version, name: :pull_request_stacks_version_check)
    |> check_constraint(:number, name: :pull_request_stacks_number_check)
    |> foreign_key_constraint(:repository_id)
  end

  defp put_programmatic_change(changeset, attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end
end
