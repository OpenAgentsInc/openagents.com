defmodule OpenAgents.Stacks.StackEntry do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pull_request_stack_entries" do
    belongs_to :stack, OpenAgents.Stacks.Stack
    belongs_to :pull_request, OpenAgents.PullRequests.PullRequest
    field :position, :integer
    field :boundary_oid, OpenAgents.Stacks.OID
    field :observed_head_oid, OpenAgents.Stacks.OID
    field :removed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:position, :boundary_oid, :observed_head_oid, :removed_at])
    |> put_programmatic_change(attrs, :stack_id)
    |> put_programmatic_change(attrs, :pull_request_id)
    |> validate_required([
      :stack_id,
      :pull_request_id,
      :position,
      :boundary_oid,
      :observed_head_oid
    ])
    |> validate_number(:position, greater_than_or_equal_to: 1)
    |> unique_constraint([:stack_id, :position],
      name: :pull_request_stack_entries_active_position_index
    )
    |> unique_constraint(:pull_request_id,
      name: :pull_request_stack_entries_active_pull_request_index
    )
    |> check_constraint(:position, name: :pull_request_stack_entries_position_check)
    |> foreign_key_constraint(:stack_id)
    |> foreign_key_constraint(:pull_request_id)
  end

  defp put_programmatic_change(changeset, attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end
end
