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
  @max_future_skew_seconds 300

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

  @doc "How far into the future a `retired_at` may sit, to absorb clock skew."
  def max_future_skew_seconds, do: @max_future_skew_seconds

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

  @doc """
  Retires the key at `retired_at`, refusing a timestamp that would rewrite
  history.

  `active_at?/2` reads the half-open window `[activated_at, retired_at)`, so
  a `retired_at` at or before an attestation's `attested_at` flips that
  already-signed attestation to unverified without touching its row. The
  changeset therefore refuses a `retired_at`:

    * at or before the newest attestation the key signed
      (`:latest_attested_at`, queried by the caller), naming the conflicting
      attestation time in the error;
    * earlier than the key's own `activated_at` when it signed nothing —
      `activated_at` rather than `inserted_at`, because `activated_at` is the
      required field that opens the window `active_at?/2` reads, while
      `inserted_at` is only the row's insertion time;
    * more than #{@max_future_skew_seconds} seconds in the future, so a
      retirement records when the key actually stopped rather than a claim
      about a time that has not happened.

  There is deliberately no override: an operator who needs an earlier
  boundary is asking to unverify signatures that were already published as
  valid, and #191 exists because that must be a refusal, not an option.
  """
  def retire_changeset(record, retired_at, opts \\ []) do
    record
    |> cast(%{retired_at: retired_at}, ~w(retired_at)a)
    |> validate_required(~w(retired_at)a)
    |> validate_not_future()
    |> validate_after_signed_history(Keyword.get(opts, :latest_attested_at))
  end

  defp validate_not_future(changeset) do
    horizon = DateTime.add(DateTime.utc_now(), @max_future_skew_seconds, :second)

    validate_change(changeset, :retired_at, fn :retired_at, retired_at ->
      if DateTime.compare(retired_at, horizon) == :gt do
        [
          retired_at: "cannot sit more than #{@max_future_skew_seconds} seconds in the future"
        ]
      else
        []
      end
    end)
  end

  defp validate_after_signed_history(changeset, %DateTime{} = latest_attested_at) do
    validate_change(changeset, :retired_at, fn :retired_at, retired_at ->
      if DateTime.compare(retired_at, latest_attested_at) == :gt do
        []
      else
        [
          retired_at:
            "cannot be at or before the newest attestation this key signed " <>
              "(attested at #{DateTime.to_iso8601(latest_attested_at)})"
        ]
      end
    end)
  end

  defp validate_after_signed_history(changeset, nil) do
    activated_at = changeset.data.activated_at

    validate_change(changeset, :retired_at, fn :retired_at, retired_at ->
      if is_nil(activated_at) or DateTime.compare(retired_at, activated_at) != :lt do
        []
      else
        [
          retired_at:
            "cannot be earlier than the key's activation " <>
              "(activated at #{DateTime.to_iso8601(activated_at)})"
        ]
      end
    end)
  end

  @doc "Whether the key was admitted and not yet retired at `instant`."
  @spec active_at?(t(), DateTime.t()) :: boolean()
  def active_at?(%__MODULE__{} = key, %DateTime{} = instant) do
    DateTime.compare(instant, key.activated_at) != :lt and
      (is_nil(key.retired_at) or DateTime.compare(instant, key.retired_at) == :lt)
  end
end
