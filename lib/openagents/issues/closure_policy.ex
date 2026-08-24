defmodule OpenAgents.Issues.ClosurePolicy do
  @moduledoc """
  One repository's opt-in for grading and for verified closing
  (`repository_closure_policies`).

  Two flags, both false by default, and the absent row means the same thing as
  the row with both false. That equivalence is the point: a repository that has
  never been asked has not consented, and a policy that treats silence as
  consent would close issues in repositories nobody opted in.

  `agents_enabled` decides whether an agent-authored claim is graded at all.
  False makes every claim `not_applicable` — the accepted-outcome contract's
  own word for work outside the gate — which is not a refusal and not a
  failure.

  `verified_closing_enabled` decides whether an accepted claim may move the
  issue. False records the verdict and the evidence and leaves the issue open,
  which is the useful half of this feature on its own: a person reads what was
  claimed and decides.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.Repositories.Repository

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "repository_closure_policies" do
    field :agents_enabled, :boolean, default: false
    field :verified_closing_enabled, :boolean, default: false

    belongs_to :repository, Repository
    belongs_to :updated_by_user, User

    timestamps()
  end

  @doc false
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :repository_id,
      :agents_enabled,
      :verified_closing_enabled,
      :updated_by_user_id
    ])
    |> validate_required([:repository_id, :agents_enabled, :verified_closing_enabled])
    |> unique_constraint(:repository_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:updated_by_user_id)
  end
end
