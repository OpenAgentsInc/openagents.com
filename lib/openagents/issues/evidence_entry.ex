defmodule OpenAgents.Issues.EvidenceEntry do
  @moduledoc """
  One edge binding an issue to a receipt that evaluated an exact commit
  (`issue_evidence`).

  The row is an edge, never a work record. It stores no steps, no report, no
  budget, and no output: the execution stays in `work_jobs`, the attempt stays
  in `forge_assignments`, and the receipt stays immutable in the table its
  family owns. What this row adds is the one fact none of them carried — which
  requested outcome the receipt is evidence for.

  Four columns make the edge readable without a join, and each is copied from
  the receipt rather than derived: `family` says which receipt family the row
  binds, `plane` says which of the two deployment planes the receipt lives in,
  `environment` says which environment the receipt reached, and `result` is the
  receipt's own terminal word.

  `{issue_id, commit_sha, family, receipt_id}` is unique, which is what makes
  WAL replay, `OpenAgents.Forge.Pushes.reconcile_receipts/1`, and a force push
  that re-presents the same commits all idempotent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Repositories.Repository

  @type t :: %__MODULE__{}

  @families ~w(push build deployment qualification)
  @planes ~w(forge tenant)
  @sources ~w(closing_reference assignment)

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "issue_evidence" do
    field :commit_sha, :string
    field :family, :string
    field :receipt_id, :binary_id
    field :plane, :string
    field :environment, :string
    field :result, :string
    field :actor, :string
    field :source, :string

    belongs_to :repository, Repository, type: :binary_id
    belongs_to :issue, Issue
    belongs_to :assignment, Assignment, type: :binary_id
    field :transparency_tier, :string, default: "ledger"
    belongs_to :artifact_link, OpenAgents.Transparency.ArtifactLink, type: :binary_id

    timestamps(updated_at: false)
  end

  @doc "The receipt families an evidence edge may bind."
  @spec families() :: [String.t()]
  def families, do: @families

  @doc "The two deployment planes, which never mix."
  @spec planes() :: [String.t()]
  def planes, do: @planes

  @doc "How an edge was resolved to its issue."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :repository_id,
      :issue_id,
      :assignment_id,
      :commit_sha,
      :family,
      :receipt_id,
      :plane,
      :environment,
      :result,
      :actor,
      :source,
      :transparency_tier,
      :artifact_link_id
    ])
    |> update_change(:commit_sha, &String.downcase/1)
    |> validate_required([
      :repository_id,
      :issue_id,
      :commit_sha,
      :family,
      :receipt_id,
      :plane,
      :actor,
      :source
    ])
    |> validate_format(:commit_sha, ~r/\A[0-9a-f]{7,64}\z/)
    |> validate_inclusion(:family, @families)
    |> validate_inclusion(:plane, @planes)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(
      :transparency_tier,
      OpenAgents.Transparency.ArtifactLink.tiers()
    )
    |> validate_length(:environment, max: 120)
    |> validate_length(:result, max: 64)
    |> validate_length(:actor, max: 200)
    |> unique_constraint([:issue_id, :commit_sha, :family, :receipt_id])
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:assignment_id)
    |> foreign_key_constraint(:artifact_link_id)
  end
end
