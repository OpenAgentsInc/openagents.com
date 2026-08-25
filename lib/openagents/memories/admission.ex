defmodule OpenAgents.Memories.Admission do
  @moduledoc """
  One verdict on one candidate system memory, and the ground for it.

  Admission is a receipt, not an assertion. The registry does not turn a
  promise green because someone said so, and the memory store does not admit a
  claim because its author wrote `admitted` on it: the record here is what a
  status is derived from, and the `admission` field on the candidate is only
  what the author claimed.

  The record is append-only. There is no `updated_at` and nothing updates one,
  so a steward who changes their mind writes a second record rather than
  editing the first, and both stay readable.

  `memory_bucket` rides the row so the composite foreign key
  `(memory_id, memory_bucket) -> memories (id, bucket)` can pin the candidate
  to the `system` bucket. That is what lets the write path refuse an admission
  record naming a `user` or `learned` row without reading `memories` at all,
  which is how the admission path stays clear of the account boundary
  MEMORY-010 draws.

  `role` names the three record roles the specification adds. Only `admission`
  is written today; `challenge` and `refutation` are the same enum and land
  with the issue that owns them.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.Memories.Memory

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @roles ~w(admission challenge refutation)
  @verdicts ~w(admitted rejected)
  @ground_characters 2_000

  schema "memory_admissions" do
    belongs_to :memory, Memory
    field :memory_bucket, :string, default: "system"
    belongs_to :steward, User
    field :slug, :string
    field :role, :string, default: "admission"
    field :verdict, :string
    field :ground, :string
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
  Validates one admission record.

  The steward and the candidate are set on the struct rather than cast, so a
  request body can name neither who admitted nor, by extension, on whose
  authority.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:verdict, :ground])
    |> update_change(:ground, &trim/1)
    |> put_change(:role, "admission")
    |> put_change(:memory_bucket, "system")
    |> put_slug()
    |> validate_required([:memory_id, :steward_id, :slug, :role, :verdict, :ground])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:verdict, @verdicts)
    |> validate_length(:ground, min: 1, max: @ground_characters, count: :graphemes)
    |> foreign_key_constraint(:steward_id)
    # The composite key, named as the database names it. A record for a `user`
    # or `learned` row fails here rather than in a read that had to cross an
    # account to check.
    |> foreign_key_constraint(:memory_id,
      name: :memory_admissions_memory_fkey,
      message: "names no system memory"
    )
    |> check_constraint(:verdict, name: :memory_admissions_shape)
  end

  defp put_slug(changeset) do
    case get_field(changeset, :memory_id) do
      id when is_binary(id) -> put_change(changeset, :slug, "adm:" <> id)
      _absent -> changeset
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
