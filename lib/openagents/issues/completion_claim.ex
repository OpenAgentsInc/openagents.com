defmodule OpenAgents.Issues.CompletionClaim do
  @moduledoc """
  One graded completion claim (`issue_completion_claims`).

  The row is the durable half of `OpenAgents.AcceptedOutcome.evaluate/1`, which
  was a pure function with nothing behind it. It stores the verdict, the typed
  reasons, and the criterion-to-evidence mapping — never the prompt, the
  transcript, the report, or the budget those came from. The execution stays in
  `work_jobs`, the attempt stays in `forge_assignments`, the receipts stay in
  the tables their families own, and the edge between issue and receipt stays
  in `issue_evidence`. This row adds the one fact none of them carried: what
  was claimed about the issue's intent, and how that claim graded.

  `{issue_id, assignment_id, revision}` is unique. An attempt reporting one
  revision has one verdict, so resubmitting a claim regrades it rather than
  accumulating verdicts nobody can order.

  Two columns carry the close, and a database constraint —
  `issue_completion_claims_close_requires_accepted` — refuses a row that says
  it closed an issue on anything but an `accepted` verdict. `closed_by_actor`
  is a system principal and never a user id, which is how a reader tells this
  close from a person's: a person's close is an `issue_closing_references` row
  with a `closed_by_user_id` behind it.

  Two more carry the contradiction. A later receipt that disagrees with the
  evidence an accepted claim rested on stamps `contradicted_at` and names the
  edge that disagreed. It never reopens the issue and never rewrites the
  verdict, because reopening on a later signal is a separate policy with its
  own failure modes (`ISSUE-001`). What it does is stop the claim from reading
  as uncontested.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Issues.{EvidenceEntry, Issue}
  alias OpenAgents.Repositories.Repository

  @type t :: %__MODULE__{}

  @states ~w(accepted incomplete unauthorized failed not_applicable)

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "issue_completion_claims" do
    field :revision, :string
    field :state, :string
    field :reasons, {:array, :string}, default: []
    field :criteria, {:array, :map}, default: []
    field :verifier, :string
    field :falsifier, :string
    field :closed, :boolean, default: false
    field :closed_at, :utc_datetime_usec
    field :closed_by_actor, :string
    field :contradicted_at, :utc_datetime_usec
    field :contradiction_reason, :string

    belongs_to :repository, Repository, type: :binary_id
    belongs_to :issue, Issue
    belongs_to :assignment, Assignment, type: :binary_id
    belongs_to :contradicted_by_evidence, EvidenceEntry, type: :binary_id

    timestamps()
  end

  @doc "The verdicts a graded claim can hold."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc false
  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [
      :repository_id,
      :issue_id,
      :assignment_id,
      :revision,
      :state,
      :reasons,
      :criteria,
      :verifier,
      :falsifier,
      :closed,
      :closed_at,
      :closed_by_actor,
      :contradicted_at,
      :contradicted_by_evidence_id,
      :contradiction_reason
    ])
    |> update_change(:revision, &String.downcase/1)
    |> validate_required([:repository_id, :issue_id, :assignment_id, :revision, :state])
    |> validate_inclusion(:state, @states)
    |> validate_format(:revision, ~r/\A[0-9a-f]{7,64}\z/)
    |> validate_length(:verifier, max: 200)
    |> validate_length(:falsifier, max: 500)
    |> validate_length(:closed_by_actor, max: 200)
    |> validate_length(:contradiction_reason, max: 200)
    |> validate_close()
    |> unique_constraint([:issue_id, :assignment_id, :revision])
    |> check_constraint(:closed, name: :issue_completion_claims_close_requires_accepted)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:assignment_id)
  end

  # The same rule the database constraint holds, refused earlier and by name so
  # a caller reads `closed_without_accepted_outcome` instead of a constraint
  # violation. Both exist on purpose: the constraint is what makes the rule
  # true of every row, and this is what makes it legible.
  defp validate_close(changeset) do
    closed? = get_field(changeset, :closed)
    state = get_field(changeset, :state)
    closed_at = get_field(changeset, :closed_at)

    cond do
      not closed? -> changeset
      state != "accepted" -> add_error(changeset, :closed, "requires an accepted outcome")
      is_nil(closed_at) -> add_error(changeset, :closed_at, "is required for a closed claim")
      true -> changeset
    end
  end
end
