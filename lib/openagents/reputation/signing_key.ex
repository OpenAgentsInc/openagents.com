defmodule OpenAgents.Reputation.SigningKey do
  @moduledoc """
  One admitted attestation issuer key.

  The row carries the public key only. A private key stays in runtime
  configuration (RELEASE-002), so reading every key a verifier needs never
  grants the authority to mint an attestation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @algorithms ~w(ed25519)

  schema "reputation_signing_keys" do
    field :key_id, :string
    field :algorithm, :string
    field :public_key, :string
    field :issuer, :string
    field :activated_at, :utc_datetime_usec
    field :retired_at, :utc_datetime_usec
    timestamps()
  end

  @type t :: %__MODULE__{}

  def algorithms, do: @algorithms

  def changeset(record, attributes) do
    record
    |> cast(attributes, ~w(key_id algorithm public_key issuer activated_at retired_at)a)
    |> validate_required(~w(key_id algorithm public_key issuer activated_at)a)
    |> validate_inclusion(:algorithm, @algorithms)
    |> validate_format(:key_id, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:public_key, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:issuer, min: 1, max: 128)
    |> unique_constraint(:key_id)
    |> unique_constraint(:public_key)
  end

  def retire_changeset(record, retired_at) do
    record
    |> cast(%{retired_at: retired_at}, ~w(retired_at)a)
    |> validate_required(~w(retired_at)a)
  end

  @doc "Whether the key was admitted and not yet retired at `instant`."
  @spec active_at?(t(), DateTime.t()) :: boolean()
  def active_at?(%__MODULE__{} = key, %DateTime{} = instant) do
    DateTime.compare(instant, key.activated_at) != :lt and
      (is_nil(key.retired_at) or DateTime.compare(instant, key.retired_at) == :lt)
  end
end
