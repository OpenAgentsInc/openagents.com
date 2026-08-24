defmodule OpenAgents.Machines.Pairing do
  @moduledoc """
  One pairing window.

  The owner is not stored here. `user_id` used to be, written beside
  `machine_id` in the same approval changeset and read by nothing; the account
  it named is `machines.user_id`, reachable through the computer the approval
  created. See issue #184.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "machine_pairings" do
    field :code_digest, :binary, redact: true
    field :poll_secret_digest, :binary, redact: true
    field :name, :string
    field :tier, :string, default: "probe"
    field :platform, :string
    field :agent_version, :string
    field :roots, {:array, :string}, default: []
    field :status, :string, default: "pending"
    belongs_to :machine, OpenAgents.Machines.Machine
    field :token_ciphertext, :binary, redact: true
    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          code_digest: binary(),
          poll_secret_digest: binary(),
          name: String.t(),
          tier: String.t(),
          platform: String.t() | nil,
          agent_version: String.t() | nil,
          roots: [String.t()],
          status: String.t(),
          machine_id: Ecto.UUID.t() | nil,
          token_ciphertext: binary() | nil,
          expires_at: DateTime.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  def create_changeset(pairing, attributes) do
    pairing
    |> cast(attributes, [:name, :tier, :platform, :agent_version, :roots])
    |> validate_required([:name, :tier])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_inclusion(:tier, OpenAgents.Machines.Machine.tiers())
    |> validate_length(:platform, max: 40)
    |> validate_length(:agent_version, max: 40)
    |> validate_roots()
    |> check_constraint(:tier, name: :machine_pairings_tier_check)
  end

  defp validate_roots(changeset) do
    validate_change(changeset, :roots, fn :roots, roots ->
      cond do
        length(roots) > 16 -> [roots: "declares too many roots"]
        Enum.any?(roots, &(not is_binary(&1) or byte_size(&1) > 512)) -> [roots: "invalid root"]
        true -> []
      end
    end)
  end
end
