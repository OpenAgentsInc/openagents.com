defmodule OpenAgents.Memories.Admission do
  @moduledoc """
  One record about one system memory: a verdict on it, a challenge to it, or a
  refutation of a challenge.

  All three are receipts, not assertions. The registry does not turn a promise
  green because someone said so, and the memory store does not admit a claim
  because its author wrote `admitted` on it: the records here are what a status
  is derived from, and the `admission` field on the candidate is only what the
  author claimed.

  Every record is append-only. There is no `updated_at` and nothing updates
  one, so a steward who changes their mind writes a second record rather than
  editing the first, and both stay readable. A reversal is a further record for
  the same reason: it is how the store keeps the argument rather than the last
  word in it.

  ## The three roles

  * `admission` — a steward's verdict, `admitted` or `rejected`, slug
    `adm:<memory>`. Only a steward writes one.
  * `challenge` — any account's statement that the claim is wrong, slug
    `chl:<memory>`. A challenge carrying its own `evidence_refs` is an
    *evidenced* challenge and suspends its target; one without is recorded and
    changes nothing.
  * `refutation` — a steward's resolution of one challenge, slug
    `ref:<challenge>`, restoring the target. Only a steward writes one.

  `author_id` is who wrote the record, whichever role it carries. The column
  was `steward_id` while `admission` was the only role written; anyone may
  challenge, so the steward rule lives at the write path rather than in a
  column name that would be wrong on two roles out of three.

  ## What the database holds rather than the changeset

  `memory_bucket` rides the row so the composite foreign key
  `(memory_id, memory_bucket) -> memories (id, bucket)` can pin the target to
  the `system` bucket. That is what lets a write refuse a record naming a
  `user` or `learned` row without reading `memories` at all, which is how these
  paths stay clear of the account boundary MEMORY-010 draws.

  `challenge_role` is always the literal `challenge` on a refutation and null
  elsewhere. It exists so the second composite foreign key,
  `(challenge_id, memory_id, challenge_role) -> (id, memory_id, role)`, can
  insist that a refutation names a challenge — and one against the same memory
  it claims to restore. PostgreSQL will not put a literal in a foreign key, so
  the literal is a column the `memory_admissions_shape` constraint pins.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.Memories.{Evidence, Memory}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @roles ~w(admission challenge refutation)
  @verdicts ~w(admitted rejected)
  @ground_characters 2_000

  schema "memory_admissions" do
    belongs_to :memory, Memory
    field :memory_bucket, :string, default: "system"
    belongs_to :author, User
    belongs_to :challenge, __MODULE__
    field :challenge_role, :string
    field :slug, :string
    field :role, :string, default: "admission"
    field :verdict, :string
    field :ground, :string
    field :evidence_refs, {:array, :map}
    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "The record roles the memory store recognises."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "The verdicts an admission record may carry."
  @spec verdicts() :: [String.t()]
  def verdicts, do: @verdicts

  @doc "The longest ground the store accepts, in characters."
  @spec ground_characters() :: pos_integer()
  def ground_characters, do: @ground_characters

  @doc """
  Whether this record is an evidenced challenge.

  The one distinction recall turns on: an evidenced challenge suspends its
  target, an unevidenced one is recorded and changes nothing. An empty list
  cannot reach the table, so absence is the only unevidenced shape there is.
  """
  @spec evidenced_challenge?(t()) :: boolean()
  def evidenced_challenge?(%__MODULE__{role: "challenge", evidence_refs: [_first | _rest]}),
    do: true

  def evidenced_challenge?(%__MODULE__{}), do: false

  @doc """
  Validates one admission record: a steward's verdict on a candidate.

  The author and the target are set on the struct rather than cast, so a
  request body can name neither who admitted nor, by extension, on whose
  authority.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:verdict, :ground])
    |> put_role("admission")
    |> put_slug(:memory_id, "adm:")
    |> validate_required([:verdict])
    |> validate_inclusion(:verdict, @verdicts)
    |> validate_shape()
  end

  @doc """
  Validates one challenge: any account's statement that an admitted claim is
  wrong, and the ground for saying so.

  `evidence_refs` is the only field beyond the ground a caller may name, and it
  is optional. Carrying it is what makes the challenge evidenced, and an
  evidenced challenge is the one that suspends its target — so the shape is
  checked here and again at the table.
  """
  @spec challenge_changeset(t(), map()) :: Ecto.Changeset.t()
  def challenge_changeset(record, attrs) do
    record
    |> cast(attrs, [:ground, :evidence_refs])
    |> put_role("challenge")
    |> put_slug(:memory_id, "chl:")
    |> Evidence.validate(:evidence_refs)
    |> validate_shape()
  end

  @doc """
  Validates one refutation: a steward's resolution of one challenge.

  The challenge and the memory it restores are set on the struct, so a request
  body names neither. The ground is all a caller supplies.
  """
  @spec refutation_changeset(t(), map()) :: Ecto.Changeset.t()
  def refutation_changeset(record, attrs) do
    record
    |> cast(attrs, [:ground])
    |> put_role("refutation")
    |> put_change(:challenge_role, "challenge")
    |> put_slug(:challenge_id, "ref:")
    |> validate_required([:challenge_id])
    |> foreign_key_constraint(:challenge_id,
      name: :memory_admissions_challenge_fkey,
      message: "names no challenge against this memory"
    )
    |> validate_shape()
  end

  # Everything the three roles agree on. `role` is put rather than cast, so no
  # request body can turn a challenge into a refutation and no caller reaches a
  # steward-only role through the path that does not check for one.
  defp put_role(changeset, role) do
    changeset
    |> update_change(:ground, &trim/1)
    |> put_change(:role, role)
    |> put_change(:memory_bucket, "system")
  end

  defp validate_shape(changeset) do
    changeset
    |> validate_required([:memory_id, :author_id, :slug, :role, :ground])
    |> validate_inclusion(:role, @roles)
    |> validate_length(:ground, min: 1, max: @ground_characters, count: :graphemes)
    |> foreign_key_constraint(:author_id)
    # The composite key, named as the database names it. A record for a `user`
    # or `learned` row fails here rather than in a read that had to cross an
    # account to check.
    |> foreign_key_constraint(:memory_id,
      name: :memory_admissions_memory_fkey,
      message: "names no system memory"
    )
    |> check_constraint(:verdict, name: :memory_admissions_shape)
    |> check_constraint(:evidence_refs,
      name: :memory_admissions_shape,
      message: "does not satisfy the record shape"
    )
  end

  defp put_slug(changeset, field, prefix) do
    case get_field(changeset, field) do
      id when is_binary(id) -> put_change(changeset, :slug, prefix <> id)
      _absent -> changeset
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
