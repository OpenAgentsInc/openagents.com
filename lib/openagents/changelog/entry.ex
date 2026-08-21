defmodule OpenAgents.Changelog.Entry do
  @moduledoc """
  One authored-or-derived public changelog entry (`changelog_entries`,
  spec §3): the human note over a change, joined to the receipts that prove
  it. Append-only and never authority — the pushed commit and the receipt
  rows remain the only truth about what shipped (A7 discipline).

  `source` records who wrote the human note: Sarah's coding job, a commit
  trailer, an operator, or the one-time `backfill` seed from `CHANGELOG.md`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @categories ~w(ui voice feature fix infra forge memory agents privacy incident)
  @sources ~w(coding_job commit_trailer operator backfill)
  @visibilities ~w(l1 l2 l3)

  schema "changelog_entries" do
    field :repo, :string
    field :sha, :string
    field :summary, :string
    field :category, :string
    field :visibility, :string, default: "l2"
    field :disclosure_after, :utc_datetime_usec
    field :source, :string
    field :entry_at, :utc_datetime_usec
    field :trace_ref, :string
    field :trace_digest, :string
    field :detail, :map, default: %{}
    field :push_receipt_id, :binary_id
    field :build_receipt_id, :binary_id
    field :target_id, :binary_id
    field :deploy_receipt_id, :binary_id
    timestamps(updated_at: false)
  end

  def categories, do: @categories
  def sources, do: @sources

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :repo,
      :sha,
      :summary,
      :category,
      :visibility,
      :disclosure_after,
      :source,
      :entry_at,
      :trace_ref,
      :trace_digest,
      :detail,
      :push_receipt_id,
      :build_receipt_id,
      :target_id,
      :deploy_receipt_id
    ])
    |> validate_required([:repo, :sha, :summary, :category, :source, :entry_at])
    |> validate_format(:sha, ~r/^[0-9a-f]{7,40}$/)
    # 255, because that is what the column is. This said 500, so a summary
    # between the two passed validation and then raised
    # `string_data_right_truncation` from Postgres -- a changeset error turned
    # into a crash, on the one path that writes this table.
    |> validate_length(:summary, max: 255)
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:visibility, @visibilities)
    |> unique_constraint([:repo, :sha, :source])
  end
end
