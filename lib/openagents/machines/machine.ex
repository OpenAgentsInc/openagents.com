defmodule OpenAgents.Machines.Machine do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @tiers ~w(probe curated shell)

  schema "machines" do
    belongs_to :user, OpenAgents.Accounts.User
    field :name, :string
    field :tier, :string, default: "probe"
    field :platform, :string
    field :agent_version, :string
    field :roots, {:array, :string}, default: []
    field :token_digest, :binary, redact: true
    field :token_expires_at, :utc_datetime_usec
    field :status, :string, default: "active"
    field :revoked_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :last_probe, :map

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          name: String.t(),
          tier: String.t(),
          platform: String.t() | nil,
          agent_version: String.t() | nil,
          roots: [String.t()],
          token_digest: binary(),
          token_expires_at: DateTime.t(),
          status: String.t(),
          revoked_at: DateTime.t() | nil,
          last_seen_at: DateTime.t() | nil,
          last_probe: map() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  def tiers, do: @tiers

  def create_changeset(machine, attributes) do
    machine
    |> cast(attributes, [:name, :tier, :platform, :agent_version, :roots])
    |> validate_required([:name, :tier])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_inclusion(:tier, @tiers)
    |> validate_length(:platform, max: 40)
    |> validate_length(:agent_version, max: 40)
    |> validate_roots()
    |> check_constraint(:tier, name: :machines_tier_check)
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
