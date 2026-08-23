defmodule OpenAgents.Forum.TipDestination do
  @moduledoc """
  Where an account wants tips to arrive.

  The row records a destination the account controls — a Bolt 12 offer, an
  LNURL address, or an on-chain address — plus a fingerprint the owner can
  compare against their own wallet. It never records a key, a seed, a channel,
  or a node credential, so the forum can route sats without being able to hold
  or spend them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User

  @kinds ["bolt12", "lnurl", "onchain"]
  @states ["active", "retired"]
  @maximum_destination_bytes 2048

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "forum_tip_destinations" do
    field :kind, :string
    field :destination, :string
    field :fingerprint, :string
    field :label, :string

    field :state, :string, default: "active"
    field :accepting_tips, :boolean, default: true
    field :retired_at, :utc_datetime_usec

    belongs_to :user, User, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds

  def changeset(destination, attrs) do
    destination
    |> cast(attrs, [
      :user_id,
      :kind,
      :destination,
      :label,
      :state,
      :accepting_tips,
      :retired_at
    ])
    |> update_change(:destination, &String.trim/1)
    |> validate_required([:user_id, :kind, :destination])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> validate_length(:destination, min: 8, max: @maximum_destination_bytes)
    |> validate_length(:label, max: 80)
    |> validate_destination_shape()
    |> put_fingerprint()
    |> unique_constraint(:user_id,
      name: :forum_tip_destinations_one_active_per_user_index,
      message: "already has an active destination"
    )
  end

  @doc """
  A stable, non-reversible name for a destination.

  The owner can match it against their wallet without the forum publishing
  where the sats go.
  """
  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(destination) when is_binary(destination) do
    :crypto.hash(:sha256, "openagents.forum.tip_destination.v1:" <> destination)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp put_fingerprint(changeset) do
    case get_field(changeset, :destination) do
      value when is_binary(value) -> put_change(changeset, :fingerprint, fingerprint(value))
      _missing -> changeset
    end
  end

  defp validate_destination_shape(changeset) do
    kind = get_field(changeset, :kind)
    value = get_field(changeset, :destination)

    cond do
      not is_binary(kind) or not is_binary(value) ->
        changeset

      String.match?(value, ~r/\s/) ->
        add_error(changeset, :destination, "must not contain whitespace")

      valid_shape?(kind, value) ->
        changeset

      true ->
        add_error(changeset, :destination, "does not look like a #{kind} destination")
    end
  end

  defp valid_shape?("bolt12", value), do: String.match?(value, ~r/\Alno1[a-z0-9]+\z/i)

  defp valid_shape?("lnurl", value) do
    String.match?(value, ~r/\A[^@\s]+@[a-z0-9.-]+\.[a-z]{2,}\z/i) or
      String.match?(value, ~r/\Alnurl1[a-z0-9]+\z/i)
  end

  defp valid_shape?("onchain", value),
    do: String.match?(value, ~r/\A(bc1[a-z0-9]{20,}|[13][a-km-zA-HJ-NP-Z1-9]{25,34})\z/)

  defp valid_shape?(_kind, _value), do: false
end
