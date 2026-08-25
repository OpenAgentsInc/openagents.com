defmodule OpenAgents.Memories.Memory do
  @moduledoc """
  One thing the account asked to have remembered, or one thing the server
  learned on its behalf.

  A memory is account-scoped and authoritative. That is what separates it from
  the memory planes in `OpenAgents.Memory` (`docs/taxonomy.md`), which are
  disposable projections of messages that still exist underneath them: delete
  a memory and nothing can rebuild it, because the sentence a reader typed once
  is the only copy.

  Two buckets, kept distinct because they earn attention differently:

  * `user` — the reader said "remember that I prefer X". Explicit only, never
    inferred from what a turn happened to contain.
  * `learned` — server-side consolidation over thread events produced it. It
    carries `source_ref` so a wrong learning is traced back to the work that
    taught it.

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

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @buckets ~w(user learned)
  @default_bucket "user"
  @body_characters 2_000
  @source_ref_characters 200

  schema "memories" do
    belongs_to :user, User
    field :bucket, :string, default: "user"
    field :body, :string, redact: true
    field :source_ref, :string
    field :embedding, {:array, :float}
    field :embedding_model, :string
    # The generated `tsvector` the lexical stand-in ranks over. PostgreSQL
    # writes it; nothing here reads it back, so it never rides a select.
    field :search_vector, :string, load_in_query: false
    belongs_to :superseded_by, __MODULE__, foreign_key: :superseded_by_id
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "The buckets a memory may be written into."
  @spec buckets() :: [String.t()]
  def buckets, do: @buckets

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
    |> cast(attrs, [:bucket, :body, :source_ref, :embedding, :embedding_model])
    |> update_change(:body, &trim/1)
    |> update_change(:source_ref, &trim/1)
    |> validate_required([:bucket, :body])
    |> validate_inclusion(:bucket, @buckets)
    |> validate_length(:body, min: 1, max: @body_characters, count: :graphemes)
    |> validate_length(:source_ref, min: 1, max: @source_ref_characters, count: :graphemes)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:body, name: :memories_shape)
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
