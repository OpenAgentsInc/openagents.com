defmodule OpenAgents.Reputation.Claim do
  @moduledoc """
  The canonical attestation claim: the exact object a signature covers.

  A claim binds the issuer key, the subject, the accepted outcome, the
  repository scope, the revision, the artifact digest, the verifier policy,
  the confidence, the evidence, and a nonce. Changing any of those changes the
  claim digest, so one attestation cannot be presented for another issue,
  revision, verifier, or actor.

  Signing and verification use Ed25519 through `:crypto`, over the canonical
  JSON encoding from `OpenAgents.Provenance.Canonical`.
  """

  alias OpenAgents.Provenance.Canonical

  @schema "openagents.reputation.attestation.v1"
  @algorithm "ed25519"

  @type claim :: %{optional(String.t()) => term()}

  def schema, do: @schema
  def algorithm, do: @algorithm

  @doc "A fresh Ed25519 keypair. The private key is never persisted."
  @spec generate_keypair() :: %{key_id: String.t(), public_key: String.t(), private_key: binary()}
  def generate_keypair do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      key_id: key_id(public_key),
      public_key: Base.encode16(public_key, case: :lower),
      private_key: private_key
    }
  end

  @doc "The public key that `private_key` signs for, hex encoded."
  @spec public_key_for(binary()) :: String.t()
  def public_key_for(private_key) when is_binary(private_key) do
    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519, private_key)
    Base.encode16(public_key, case: :lower)
  end

  @doc "The key identifier for a raw or hex encoded public key."
  @spec key_id(binary()) :: String.t()
  def key_id(public_key) when is_binary(public_key) do
    public_key |> decode_key() |> Canonical.sha256()
  end

  @doc """
  The canonical claim for `attributes`.

  A `private` transparency tier keeps references out of the signed object:
  the claim carries each reference's kind, digest, and observation time, and
  the outcome's digest without its receipt reference. The published claim
  stays complete and verifiable and discloses nothing about the work.
  """
  @spec build(map()) :: claim()
  def build(attributes) do
    %{
      "schema" => @schema,
      "event_type" => attributes.event_type,
      "issuer" => %{
        "key_id" => attributes.issuer_key_id,
        "algorithm" => @algorithm,
        "public_key" => attributes.issuer_public_key
      },
      "subject" => %{"actor_id" => attributes.subject_id},
      "outcome" => %{
        "kind" => attributes.outcome_kind,
        "ref" => if(disclosed?(attributes.transparency_tier), do: attributes.outcome_ref),
        "digest" => attributes.outcome_digest,
        "state" => attributes.outcome_state
      },
      "scope" => %{
        "repository" => attributes.repository,
        "repository_id" => attributes.repository_id,
        "issue_number" => attributes.issue_number,
        "revision" => attributes.revision,
        "artifact_digest" => attributes.artifact_digest
      },
      "verifier" => %{
        "policy_id" => attributes.policy_id,
        "policy_version" => attributes.policy_version,
        "policy_digest" => attributes.policy_digest
      },
      "confidence_ppm" => attributes.confidence_ppm,
      "transparency_tier" => attributes.transparency_tier,
      "evidence" => evidence(attributes.evidence, attributes.transparency_tier),
      "attested_at" => DateTime.to_iso8601(attributes.attested_at),
      "nonce" => attributes.nonce,
      "supersedes" => attributes[:supersedes_digest]
    }
  end

  @doc "The canonical digest of `claim`."
  @spec digest(claim()) :: {:ok, String.t()} | {:error, term()}
  def digest(claim), do: Canonical.digest(claim)

  @doc "Signs the canonical encoding of `claim` with an Ed25519 private key."
  @spec sign(claim(), binary()) :: {:ok, String.t()} | {:error, term()}
  def sign(claim, private_key) when is_binary(private_key) do
    with {:ok, encoded} <- Canonical.encode(claim) do
      signature = :crypto.sign(:eddsa, :none, encoded, [private_key, :ed25519])
      {:ok, Base.encode16(signature, case: :lower)}
    end
  end

  @doc "Whether `signature` covers `claim` under `public_key`."
  @spec valid_signature?(claim(), String.t(), String.t()) :: boolean()
  def valid_signature?(claim, signature, public_key) do
    with {:ok, encoded} <- Canonical.encode(claim),
         {:ok, raw_signature} <- Base.decode16(signature, case: :mixed) do
      :crypto.verify(:eddsa, :none, encoded, raw_signature, [decode_key(public_key), :ed25519])
    else
      _other -> false
    end
  rescue
    ErlangError -> false
  end

  @doc "A fresh claim nonce."
  @spec nonce() :: String.t()
  def nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp evidence(entries, tier) do
    entries
    |> Enum.map(&entry(&1, tier))
    |> Enum.sort_by(& &1["digest"])
  end

  defp entry(entry, tier) do
    entry = Map.new(entry, fn {key, value} -> {to_string(key), value} end)
    disclosed? = disclosed?(tier)

    %{
      "kind" => entry["kind"],
      "ref" => if(disclosed?, do: entry["ref"]),
      "digest" => entry["digest"],
      "observed_at" => entry["observed_at"],
      "disclosed" => disclosed?
    }
  end

  defp disclosed?(tier), do: tier != "private"

  defp decode_key(key) when byte_size(key) == 64 do
    case Base.decode16(key, case: :mixed) do
      {:ok, raw} -> raw
      :error -> key
    end
  end

  defp decode_key(key), do: key
end
