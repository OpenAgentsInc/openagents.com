defmodule OpenAgents.Stacks.CheckRun do
  @moduledoc """
  One check evaluation of one stacked pull request layer.

  Validity keys to the full context — `(pull_request_id, workflow_name,
  context, head_oid, effective_base_oid, workflow_definition_oid)` — never
  to the head OID alone (docs/stacked-prs.md section 11.3). `tested_oid` is
  the immutable snapshot the check actually runs against: the layer head
  when the stack is rebased onto the current trunk, otherwise a synthetic
  commit published under `refs/internal/checks/<run-id>` whose tree is the
  current trunk plus every layer through this position (section 11.4).

  A trunk advance changes the effective base OID, so existing runs no
  longer match the current identity and become `stale` rather than
  silently vouching for a state that no longer exists.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @states ~w(pending passed failed stale)
  @contexts ~w(layer merge_group)
  @run_on_policies ~w(every_layer top_layer_only bottom_layer_only changed_paths merge_group_only)

  schema "stack_check_runs" do
    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :stack, OpenAgents.Stacks.Stack
    belongs_to :pull_request, OpenAgents.PullRequests.PullRequest

    field :workflow_name, :string
    field :run_on, :string
    field :required, :boolean, default: false
    field :run_reason, :string
    field :context, :string, default: "layer"

    field :head_oid, OpenAgents.Stacks.OID
    field :effective_base_oid, OpenAgents.Stacks.OID
    field :workflow_definition_oid, OpenAgents.Stacks.OID
    field :tested_oid, OpenAgents.Stacks.OID
    field :synthetic_ref, :string

    field :state, :string, default: "pending"
    field :concluded_at, :utc_datetime_usec

    timestamps()
  end

  def states, do: @states
  def contexts, do: @contexts
  def run_on_policies, do: @run_on_policies

  def changeset(check_run, attrs) do
    check_run
    |> cast(attrs, [
      :workflow_name,
      :run_on,
      :required,
      :run_reason,
      :context,
      :head_oid,
      :effective_base_oid,
      :workflow_definition_oid,
      :tested_oid,
      :synthetic_ref,
      :state
    ])
    |> put_programmatic_change(attrs, :id)
    |> put_programmatic_change(attrs, :repository_id)
    |> put_programmatic_change(attrs, :stack_id)
    |> put_programmatic_change(attrs, :pull_request_id)
    |> validate_required([
      :repository_id,
      :stack_id,
      :pull_request_id,
      :workflow_name,
      :run_on,
      :run_reason,
      :context,
      :head_oid,
      :effective_base_oid,
      :workflow_definition_oid,
      :tested_oid,
      :state
    ])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:context, @contexts)
    |> validate_inclusion(:run_on, @run_on_policies)
    |> unique_constraint(
      [
        :pull_request_id,
        :workflow_name,
        :context,
        :head_oid,
        :effective_base_oid,
        :workflow_definition_oid
      ],
      name: :stack_check_runs_identity_index
    )
    |> check_constraint(:state, name: :stack_check_runs_state_check)
    |> check_constraint(:context, name: :stack_check_runs_context_check)
    |> check_constraint(:run_on, name: :stack_check_runs_run_on_check)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:stack_id)
    |> foreign_key_constraint(:pull_request_id)
  end

  @doc "Concludes a pending run as passed or failed."
  def conclusion_changeset(check_run, state, concluded_at) when state in ~w(passed failed) do
    change(check_run, state: state, concluded_at: concluded_at)
  end

  @doc "Marks a run stale: its effective base no longer matches the trunk."
  def stale_changeset(check_run) do
    change(check_run, state: "stale")
  end

  defp put_programmatic_change(changeset, attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end
end
