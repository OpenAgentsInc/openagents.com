defmodule OpenAgents.Memories.Memory do
  @moduledoc """
  One thing the account asked to have remembered, or one thing the server
  learned on its behalf.

  A memory is account-scoped and authoritative. That is what separates it from
  the memory planes in `OpenAgents.Memory` (`docs/taxonomy.md`), which are
  disposable projections of messages that still exist underneath them: delete
  a memory and nothing can rebuild it, because the sentence a reader typed once
  is the only copy.

  Three buckets, kept distinct because they earn attention differently:

  * `user` — the reader said "remember that I prefer X". Explicit only, never
    inferred from what a turn happened to contain.
  * `learned` — server-side consolidation over thread events produced it. It
    carries `source_ref` so a wrong learning is traced back to the work that
    taught it.
  * `system` — what the network as a whole has learned. See
    `OpenAgents.Memories.Admissions`.

  A `system` row carries fields the other two do not, and they are required
  together: a `sys:` slug, a transparency `tier` of `ledger` or `glass`, an
  `as_of` date for the claim, an `admission` the author claims, and a non-empty
  `evidence_refs` list. A `user` or `learned` row carries none of them. Both
  halves of that rule are a database constraint (`memories_system_shape`) as
  well as a validation here, so an evidence-free candidate is unrepresentable
  rather than merely unwritten by the code that exists today.

  `admission` is the author's claim and nothing more. Effective status comes
  from `OpenAgents.Memories.Admissions.status/1`, which reads the admission
  records, so a row that says `admitted` with no steward record behind it still
  reads as a candidate.

  A system row may also carry a `stance`, and one that does is a **promotion
  tombstone**: the claim was promoted to a reviewed knowledge-base stance, this
  row supersedes the claim, and its body names the stance that replaced it. See
  `OpenAgents.Memories.Promotions`.

  `superseded_by_id` is how a correction lands. The replacement is a new row
  and the old row points at it, so the store keeps the chain rather than
  overwriting the mistake. Nothing here updates `body`: a memory's text is
  fixed for the life of the row.

  `user_id` is set on the struct and never cast, so a request body cannot name
  whose memory it is writing.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.Memories.Evidence

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @buckets ~w(user learned system)
  @recallable_buckets ~w(user learned)
  @default_bucket "user"
  @body_characters 2_000
  @source_ref_characters 200
  @slug_characters 200
  @slug_prefix "sys:"
  @tiers ~w(ledger glass)
  @admissions ~w(candidate admitted rejected)
  @stance_characters 200
  # A knowledge-base stance id: lowercase words joined by hyphens, as the
  # corpus writes them (`earning-bitcoin`, `coder-tiers`).
  @stance_format ~r/^[a-z0-9]+(-[a-z0-9]+)*$/

  schema "memories" do
    belongs_to :user, User
    field :bucket, :string, default: "user"
    field :body, :string, redact: true
    field :source_ref, :string
    field :embedding, {:array, :float}
    field :embedding_model, :string

    # The system bucket's fields. Null on every other row.
    field :slug, :string
    field :entity, :string
    field :tier, :string
    field :as_of, :date
    field :admission, :string
    field :evidence_refs, {:array, :map}

    # The knowledge-base stance this claim was promoted to. A row carrying one
    # is a promotion tombstone: the claim's live home is the reviewed stance,
    # and this row exists to say so. Null on every other row.
    field :stance, :string

    # Whether this row is a promotion tombstone. PostgreSQL generates it from
    # `stance`, so it cannot disagree; it exists as a column because a foreign
    # key can reference one and an expression cannot. Read back after a write,
    # never written.
    field :promoted, :boolean, read_after_writes: true

    # The generated `tsvector` the lexical stand-in ranks over. PostgreSQL
    # writes it; nothing here reads it back, so it never rides a select.
    field :search_vector, :string, load_in_query: false

    # What `OpenAgents.Memories.Admissions` derived for this row, carried so a
    # note can print the status a steward's receipts produce rather than the
    # `admission` field the author claimed. Virtual on purpose: a derived
    # status has no column, because a column is exactly the thing an author
    # could write for themselves.
    field :derived_status, :string, virtual: true
    belongs_to :superseded_by, __MODULE__, foreign_key: :superseded_by_id
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "The buckets a memory may be written into."
  @spec buckets() :: [String.t()]
  def buckets, do: @buckets

  @doc """
  The buckets account-scoped recall reads.

  `system` is not one of them and never becomes one. Reading an admitted system
  row into every account's turn is cross-account recall by construction, so it
  cannot ride the query that names `user_id`; it has a plane of its own in
  `OpenAgents.Memories.SystemRecall`, under an eligibility filter that replaces
  the scope predicate and a feature flag that is off by default (MEMORY-001).
  Widening this list would surface the bucket without either one, so it stays
  two buckets long.
  """
  @spec recallable_buckets() :: [String.t()]
  def recallable_buckets, do: @recallable_buckets

  @doc "The transparency tiers a system memory may carry."
  @spec tiers() :: [String.t()]
  def tiers, do: @tiers

  @doc "The admission states an author may claim."
  @spec admissions() :: [String.t()]
  def admissions, do: @admissions

  @doc "The kinds of evidence a system memory may cite."
  @spec evidence_kinds() :: [String.t()]
  def evidence_kinds, do: Evidence.kinds()

  @doc """
  Whether this row is a promotion tombstone.

  A tombstone is a pointer at a reviewed stance, not a claim of its own: no
  admission, challenge, or refutation may name one, and nothing can admit it, so
  it reaches no session's recall.
  """
  @spec promoted?(t()) :: boolean()
  def promoted?(%__MODULE__{stance: stance}), do: is_binary(stance)

  @doc "The longest stance id the store accepts, in characters."
  @spec stance_characters() :: pos_integer()
  def stance_characters, do: @stance_characters

  @doc "The prefix every system slug carries."
  @spec slug_prefix() :: String.t()
  def slug_prefix, do: @slug_prefix

  @doc "The bucket a write lands in when it names none."
  @spec default_bucket() :: String.t()
  def default_bucket, do: @default_bucket

  @doc "The longest body the store accepts, in characters."
  @spec body_characters() :: pos_integer()
  def body_characters, do: @body_characters

  @doc """
  Validates one new memory. The owner is not cast: pass it on the struct.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [
      :bucket,
      :body,
      :source_ref,
      :embedding,
      :embedding_model,
      :slug,
      :entity,
      :tier,
      :as_of,
      :admission,
      :evidence_refs,
      :stance
    ])
    |> update_change(:body, &trim/1)
    |> update_change(:source_ref, &trim/1)
    |> update_change(:slug, &trim/1)
    |> update_change(:entity, &trim/1)
    |> update_change(:stance, &trim/1)
    |> validate_required([:bucket, :body])
    |> validate_inclusion(:bucket, @buckets)
    |> validate_length(:body, min: 1, max: @body_characters, count: :graphemes)
    |> validate_length(:source_ref, min: 1, max: @source_ref_characters, count: :graphemes)
    |> validate_bucket_fields()
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:body, name: :memories_shape)
    |> check_constraint(:evidence_refs,
      name: :memories_system_shape,
      message: "does not satisfy the system-memory shape"
    )
  end

  # The system fields, required together on a system row and refused outright
  # on the other two. The database says the same thing in
  # `memories_system_shape`; this is the half that can explain itself to the
  # caller.
  defp validate_bucket_fields(changeset) do
    case get_field(changeset, :bucket) do
      "system" -> validate_system(changeset)
      _account_scoped -> refuse_system_fields(changeset)
    end
  end

  defp validate_system(changeset) do
    changeset
    |> validate_required([:slug, :tier, :as_of, :admission, :evidence_refs])
    |> validate_length(:slug, min: 1, max: @slug_characters, count: :graphemes)
    |> validate_format(:slug, ~r/^sys:/, message: "must start with #{@slug_prefix}")
    |> validate_length(:entity, min: 1, max: @slug_characters, count: :graphemes)
    |> validate_inclusion(:tier, @tiers)
    |> validate_inclusion(:admission, @admissions)
    |> Evidence.validate(:evidence_refs)
    |> validate_stance()
  end

  # A stance is optional — most system rows carry none — but a row that names
  # one is a promotion tombstone, and both halves of that shape are checked
  # here and again at the table. `position(stance in body) > 0` is the database
  # half of "a tombstone whose body names the stance"; this is the half that can
  # explain itself to the caller.
  defp validate_stance(changeset) do
    case get_field(changeset, :stance) do
      nil ->
        changeset

      stance ->
        changeset
        |> validate_length(:stance, min: 1, max: @stance_characters, count: :graphemes)
        |> validate_format(:stance, @stance_format,
          message: "must be a knowledge-base stance id, in lowercase words joined by hyphens"
        )
        |> validate_body_names(stance)
    end
  end

  defp validate_body_names(changeset, stance) do
    body = get_field(changeset, :body)

    if is_binary(body) and String.contains?(body, stance) do
      changeset
    else
      add_error(changeset, :body, "must name the stance this claim was promoted to")
    end
  end

  defp refuse_system_fields(changeset) do
    Enum.reduce(
      [:slug, :entity, :tier, :as_of, :admission, :evidence_refs, :stance],
      changeset,
      fn
        field, acc ->
          if is_nil(get_field(acc, field)) do
            acc
          else
            add_error(acc, field, "belongs only to a system memory")
          end
      end
    )
  end

  @doc "Points a memory at the memory that replaced it."
  @spec supersede_changeset(t(), t()) :: Ecto.Changeset.t()
  def supersede_changeset(memory, replacement) do
    memory
    |> change(superseded_by_id: replacement.id)
    |> check_constraint(:superseded_by_id, name: :memories_shape)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
