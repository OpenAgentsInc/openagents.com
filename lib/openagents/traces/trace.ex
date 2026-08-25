defmodule OpenAgents.Traces.Trace do
  @moduledoc """
  An account-scoped ATIF trace upload.

  A trace is an owner-attested document with a stable digest. The server stores
  the document as received and deduplicates per owner, so re-uploading the same
  bytes returns the existing record rather than creating a duplicate.

  `visibility` is the uploader's consent, not a description of the document. It
  defaults to `dark`, and nothing raises it but the uploader. `assignment_id`,
  when present, is the attempt this trajectory was produced under, which is how
  an issue comes to know a trace exists without holding one.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Transparency

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @visibilities Enum.map(Transparency.tier_atoms(), &to_string/1)
  @default_visibility "dark"

  schema "traces" do
    field :user_id, :binary_id
    field :digest, :string
    field :visibility, :string, default: @default_visibility
    field :document, :map
    field :byte_size, :integer
    field :assignment_id, :binary_id
    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  def default_visibility, do: @default_visibility
  def visibilities, do: @visibilities

  def create_changeset(%__MODULE__{} = trace, attrs) do
    trace
    |> cast(attrs, [:digest, :visibility, :document, :byte_size, :assignment_id])
    |> put_change(:user_id, attrs.user_id)
    |> validate_required([:user_id, :digest, :visibility, :document, :byte_size])
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> validate_format(:digest, ~r/\Asha256:[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:assignment_id)
    |> unique_constraint([:user_id, :digest], name: :traces_user_id_digest_index)
  end
end
