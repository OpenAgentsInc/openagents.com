defmodule OpenAgents.Forge.KeyRotationTest do
  @moduledoc """
  Rehearsal 4 of `docs/forge-exit-rehearsals.md`, which had no executable
  proof at all until #180 performed it.

  The rehearsal asks two things of every key-like secret this forge holds:
  that rotating it leaves already-issued receipts verifiable, and that a
  rotation performed in the wrong order is refused rather than silently
  invalidating history.

  The first holds everywhere. The second holds in one of the four families,
  and the two places it does not are pinned here with the issues that carry
  them, so a fix turns a test red instead of passing unnoticed. A rehearsal
  that recorded only the half that works would be the kind of claim `EXIT-006`
  exists to prevent.

  | Family | Rotation loses nothing | Wrong order refused |
  | --- | --- | --- |
  | Forge operator token | yes — the principal is a literal, not a derivation | not applicable; there is no order |
  | Account `oa_pat_` tokens | yes — digest-only, no key under them | not applicable |
  | Reputation issuer key | forward, yes | **no** — #191 |
  | GitHub token vault | yes — key id in the envelope, keyring for the old ones | yes |
  | Machine pairing vault | **no** — #192 | no |
  | Voice recording vault | **no** — no key id, no keyring | no |

  Forge push receipts sit underneath all of it and depend on none of it:
  `OpenAgents.Forge.WAL`'s chain is unkeyed `sha256` and
  `OpenAgents.Forge.Verification` reads no secret, so no rotation in this
  table can change a `verify/1` verdict. That is asserted rather than assumed,
  because "rotation leaves every already-issued receipt verifiable" is only
  worth publishing if something checks that receipts never acquired a key
  dependency.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.CompensationFixtures
  import OpenAgents.IssuesFixtures

  alias OpenAgents.Accounts.TokenVault, as: GitHubVault
  alias OpenAgents.Forge.{Verification, WAL}
  alias OpenAgents.Machines.TokenVault, as: MachineVault
  alias OpenAgents.Reputation
  alias OpenAgents.Reputation.Claim
  alias OpenAgents.Voice.RecordingVault

  describe "forge receipts depend on no key, so no rotation can invalidate one" do
    test "the WAL chain link is unkeyed and reproducible from the entry alone" do
      entry = %{
        "seq" => 1,
        "object" => "entries/00000001-abcdef012345",
        "format" => "receive_pack",
        "principal" => "operator:forge-token",
        "pushed_at" => "2026-08-24T00:00:00.000000Z",
        "refs" => %{"refs/heads/main" => String.duplicate("a", 40)}
      }

      assert {:ok, link} = WAL.chain_link("", entry)
      assert {:ok, ^link} = WAL.chain_link("", entry)
      assert link =~ ~r/\A[0-9a-f]{64}\z/

      # It commits to the entry's contents, so it is a hash of the record and
      # not a token issued beside it.
      assert {:ok, other} = WAL.chain_link("", %{entry | "principal" => "user:someone"})
      refute other == link

      # Every key-like secret in the application changes underneath it and the
      # link is unmoved, because none of them is an input.
      rotate_every_secret(fn ->
        assert {:ok, ^link} = WAL.chain_link("", entry)
      end)
    end

    test "the verifier was compiled against no secret and no vault" do
      callees = external_calls(Verification)

      for module <- [GitHubVault, MachineVault, RecordingVault, Reputation, OpenAgents.ApiTokens] do
        refute module in callees,
               "#{inspect(module)} reached OpenAgents.Forge.Verification. A receipt that " <>
                 "depends on a key stops being verifiable the moment that key rotates, " <>
                 "which is what rehearsal 4 exists to rule out."
      end
    end
  end

  describe "the reputation issuer key" do
    setup do
      repository = repository_fixture()
      issue = issue_fixture(repository)
      assert {:ok, policy} = Reputation.admit_policy(operator())
      keypair = Claim.generate_keypair()

      assert {:ok, key} =
               Reputation.admit_key(%{public_key: keypair.public_key, issuer: "verifier"})

      %{
        repository: repository,
        issue: issue,
        policy: policy,
        key: key,
        signer: %{key_id: key.key_id, private_key: keypair.private_key}
      }
    end

    test "retiring forward keeps an attestation verified, and the successor issues", context do
      assert {:ok, attestation} = issue(context)
      assert {:ok, _retired} = Reputation.retire_key(context.key, DateTime.utc_now())

      report = Reputation.verify(attestation)
      assert report["signature"]["valid"]
      assert report["signature"]["key_status"] == "retired"
      assert report["verified"]

      assert {:error, :signing_key_retired} = issue(context)
    end

    test "retiring backward silently unverifies what the key already signed (#191)", context do
      assert {:ok, attestation} = issue(context)
      assert Reputation.verify(attestation)["verified"]

      backdated = DateTime.add(attestation.attested_at, -1, :second)
      assert {:ok, _retired} = Reputation.retire_key(context.key, backdated)

      report = Reputation.verify(attestation)

      # The signature is still valid over an unaltered claim. Only the window
      # moved, and it moved because one UPDATE against a row the operator
      # controls said so. Nothing refused it and nothing recorded it.
      assert report["digest_match"]
      assert report["signature"]["valid"]
      refute report["signature"]["key_active_at_attestation"]
      refute report["verified"]
    end

    test "the forward edge is the one that is guarded", context do
      # Issuance under a key that is not active is refused, so the asymmetry
      # in #191 is specifically the retirement edge rather than a missing
      # window check.
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      keypair = Claim.generate_keypair()

      assert {:ok, key} =
               Reputation.admit_key(%{
                 public_key: keypair.public_key,
                 issuer: "verifier",
                 activated_at: future
               })

      assert {:error, :signing_key_retired} =
               issue(%{context | signer: %{key_id: key.key_id, private_key: keypair.private_key}})
    end
  end

  describe "the three hand-rolled vaults" do
    test "the GitHub vault opens envelopes sealed under a retired key" do
      first = Base.encode64(:crypto.strong_rand_bytes(32))
      second = Base.encode64(:crypto.strong_rand_bytes(32))

      sealed =
        with_env(
          [github_token_encryption_key: first, github_token_encryption_key_id: "first"],
          fn ->
            assert {:ok, sealed, "first"} = GitHubVault.seal_with_metadata("gho_original")
            sealed
          end
        )

      # The documented order: the retiring key enters the keyring before the
      # successor becomes active.
      with_env(
        [
          github_token_encryption_key: second,
          github_token_encryption_key_id: "second",
          github_token_decryption_keys: %{"first" => first}
        ],
        fn ->
          assert {:ok, "gho_original"} = GitHubVault.open(sealed)
          assert {:ok, "first"} = GitHubVault.key_id(sealed)
        end
      )
    end

    test "the GitHub vault refuses to open an envelope whose key left the keyring" do
      first = Base.encode64(:crypto.strong_rand_bytes(32))
      second = Base.encode64(:crypto.strong_rand_bytes(32))

      sealed =
        with_env(
          [github_token_encryption_key: first, github_token_encryption_key_id: "first"],
          fn ->
            assert {:ok, sealed, "first"} = GitHubVault.seal_with_metadata("gho_original")
            sealed
          end
        )

      # The wrong order: the successor is activated and the predecessor was
      # never added to the keyring. This is the one family where the wrong
      # order fails closed rather than losing data quietly, and the rewrap
      # that would follow rolls back rather than writing an unopenable row.
      with_env(
        [
          github_token_encryption_key: second,
          github_token_encryption_key_id: "second",
          github_token_decryption_keys: %{}
        ],
        fn ->
          assert {:error, reason} = GitHubVault.open(sealed)
          assert reason in [:token_unsealable, :token_vault_not_configured]
        end
      )
    end

    test "the machine pairing vault reads the GitHub vault's active key (#192)" do
      first = Base.encode64(:crypto.strong_rand_bytes(32))
      second = Base.encode64(:crypto.strong_rand_bytes(32))

      sealed =
        with_env([github_token_encryption_key: first], fn ->
          assert {:ok, sealed} = MachineVault.seal("smct_pairing")
          assert {:ok, "smct_pairing"} = MachineVault.open(sealed)
          sealed
        end)

      # Rotating the GitHub key — the documented procedure, performed in the
      # documented order — orphans this envelope, because the machine vault
      # carries no key id and consults no keyring. The blast radius is the ten
      # minutes of unclaimed pairings the lifetime allows, which is why this
      # is filed rather than treated as an incident.
      with_env(
        [
          github_token_encryption_key: second,
          github_token_encryption_key_id: "second",
          github_token_decryption_keys: %{"first" => first}
        ],
        fn ->
          assert {:error, :token_unsealable} = MachineVault.open(sealed)
        end
      )
    end

    test "the voice recording vault has no keyring either, so its key cannot rotate" do
      first = Base.encode64(:crypto.strong_rand_bytes(32))
      second = Base.encode64(:crypto.strong_rand_bytes(32))
      recording = Ecto.UUID.generate()

      sealed =
        with_env([voice_recording_encryption_key: first], fn ->
          assert {:ok, sealed} = RecordingVault.seal("audio", recording, 1)
          sealed
        end)

      with_env([voice_recording_encryption_key: second], fn ->
        assert {:error, :chunk_unsealable} = RecordingVault.open(sealed, recording, 1)
      end)
    end
  end

  describe "the forge operator token" do
    test "rotating it changes no principal a past push already recorded" do
      # `operator:forge-token` is a literal `OpenAgents.Forge.GitHTTP` writes
      # at push time, not a derivation from the secret, so a rotation cannot
      # make a past push attributable to a person and cannot make it
      # unattributable either. There is no ordering to get wrong, and no
      # overlap window: the cutover is hard, and a pusher holding the old
      # value is refused rather than accepted under a stale principal.
      previous = Application.get_env(:openagents, :forge_operator_token)
      on_exit(fn -> restore(:forge_operator_token, previous) end)

      entry = %{
        "seq" => 7,
        "object" => "entries/00000007-0123456789ab",
        "format" => "receive_pack",
        "principal" => "operator:forge-token",
        "pushed_at" => "2026-08-24T00:00:00.000000Z",
        "refs" => %{"refs/heads/main" => String.duplicate("b", 40)}
      }

      Application.put_env(:openagents, :forge_operator_token, "before-rotation")
      assert {:ok, link} = WAL.chain_link("", entry)

      Application.put_env(:openagents, :forge_operator_token, "after-rotation")
      assert {:ok, ^link} = WAL.chain_link("", entry)
      assert entry["principal"] == "operator:forge-token"
    end
  end

  defp issue(context) do
    decision = outcome_decision_fixture()

    Reputation.issue(context.policy, context.signer, %{
      event_type: "completion",
      subject_id: "actor:builder",
      outcome: %{kind: "compensation_outcome_decision", ref: decision.decision_receipt_ref},
      repository: context.repository,
      issue_number: context.issue.number,
      revision: String.duplicate("a", 40),
      artifact_digest: OpenAgents.Provenance.Canonical.digest!(%{"nonce" => Claim.nonce()}),
      confidence_ppm: 900_000,
      transparency_tier: "public",
      evidence: [
        %{
          kind: "outcome",
          ref: decision.decision_receipt_ref,
          digest: decision.outcome_digest,
          observed_at: DateTime.to_iso8601(DateTime.utc_now())
        }
      ]
    })
  end

  defp operator do
    %{
      authenticated: true,
      actor_id: "operator:test",
      auth_method: "test_session",
      approval_receipt_ref: "rotation:#{System.unique_integer([:positive])}"
    }
  end

  defp rotate_every_secret(assertion) do
    keys = [
      :forge_operator_token,
      :github_token_encryption_key,
      :github_token_encryption_key_id,
      :voice_recording_encryption_key
    ]

    previous = Enum.map(keys, &{&1, Application.get_env(:openagents, &1)})
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore(key, value) end) end)

    for key <- keys do
      Application.put_env(:openagents, key, Base.encode64(:crypto.strong_rand_bytes(32)))
    end

    assertion.()
  end

  defp with_env(settings, function) do
    previous =
      Enum.map(settings, fn {key, _value} -> {key, Application.get_env(:openagents, key)} end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:openagents, key, value) end)

    try do
      function.()
    after
      Enum.each(previous, fn {key, value} -> restore(key, value) end)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:openagents, key)
  defp restore(key, value), do: Application.put_env(:openagents, key, value)

  defp external_calls(module) do
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
    Enum.map(imports, &elem(&1, 0))
  end
end
