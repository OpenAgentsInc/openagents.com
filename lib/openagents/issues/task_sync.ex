defmodule OpenAgents.Issues.TaskSync do
  @moduledoc """
  One automatic task-list edit (`issue_task_syncs`).

  A row exists for every body the forge rewrote on its own: which issue or
  comment it changed, which issue changing state caused it, and whether the
  checkbox ended up checked. `OpenAgentsWeb.IssueShowLive` reads the rows for
  one issue and renders them into the same history feed as comments, closes,
  and commit references, so an edit nobody made by hand is still an edit
  somebody can see.

  `principal` is always `"system"`. The forge is the actor here, not the
  person whose close triggered the rewrite: they closed an issue, they did not
  edit anyone's tracking issue, and attributing the edit to them would put
  words in their mouth. There is no `closed_by_user_id` equivalent on purpose.

  There is no unique index, and that is deliberate. The idempotency gate for
  this mechanism is the rendered body itself: `OpenAgents.Issues.TaskReferences`
  writes only when `OpenAgents.Issues.TaskList.render/2` returns something
  different from what is stored, so a repeat produces no write and no row. A
  unique key over `{issue_id, reference_issue_id}` would be wrong instead of
  redundant, because closing, reopening, and closing an issue again are three
  real edits that the history should show three times.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Issues.{Comment, Issue}
  alias OpenAgents.Repositories.Repository

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "issue_task_syncs" do
    field :reference_number, :integer
    field :checked, :boolean, default: false
    field :principal, :string, default: "system"

    belongs_to :repository, Repository, type: :binary_id
    belongs_to :issue, Issue
    belongs_to :comment, Comment
    belongs_to :reference_issue, Issue

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(sync, attrs) do
    sync
    |> cast(attrs, [
      :repository_id,
      :issue_id,
      :comment_id,
      :reference_issue_id,
      :reference_number,
      :checked,
      :principal
    ])
    |> validate_required([
      :repository_id,
      :issue_id,
      :reference_issue_id,
      :reference_number,
      :principal
    ])
    |> validate_number(:reference_number, greater_than: 0)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:reference_issue_id)
  end
end
