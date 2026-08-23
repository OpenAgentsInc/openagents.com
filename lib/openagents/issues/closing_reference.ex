defmodule OpenAgents.Issues.ClosingReference do
  @moduledoc """
  One `Closes #N` reference a commit made to an issue in the same repository
  (`issue_closing_references`).

  The row is the record of the reference, not of the close: `closed` says
  whether this reference is the one that moved the issue to `closed`, and is
  `false` when the issue was already closed. Keeping the reference either way
  is what lets the issue page link back to the commit that shipped it even
  when someone closed it by hand first.

  The row is also the idempotency gate. WAL replay, `reconcile_receipts/1`,
  and a force push that re-presents the same commits all reach the same
  `{issue_id, commit_sha}` pair, and the unique index turns the second
  attempt into a no-op rather than a second close.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Repositories.Repository

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "issue_closing_references" do
    field :commit_sha, :string
    field :repo, :string
    field :wal_seq, :integer
    field :principal, :string
    field :verb, :string
    field :closed, :boolean, default: false

    belongs_to :repository, Repository, type: :binary_id
    belongs_to :issue, Issue
    belongs_to :closed_by_user, User, type: :binary_id
    field :push_receipt_id, :binary_id

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(reference, attrs) do
    reference
    |> cast(attrs, [
      :repository_id,
      :issue_id,
      :commit_sha,
      :repo,
      :wal_seq,
      :principal,
      :verb,
      :closed,
      :closed_by_user_id,
      :push_receipt_id
    ])
    |> validate_required([:repository_id, :issue_id, :commit_sha, :principal])
    |> validate_format(:commit_sha, ~r/\A[0-9a-f]{7,64}\z/)
    |> unique_constraint([:issue_id, :commit_sha])
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:closed_by_user_id)
  end
end
