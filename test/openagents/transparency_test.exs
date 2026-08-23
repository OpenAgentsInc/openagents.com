defmodule OpenAgents.TransparencyTest do
  @moduledoc """
  Tests for `OpenAgents.Transparency` tier logic and revocation.
  """

  use OpenAgents.DataCase, async: true

  alias OpenAgents.Transparency.ArtifactLink

  import OpenAgents.Transparency,
    only: [
      allows?: 3,
      effective_tier: 2,
      redact_for_viewer: 3,
      tier_atoms: 0,
      viewer_tier: 1,
      revoke: 3
    ]

  describe "tier_atoms/0" do
    test "returns the tiers from least to most transparent" do
      assert tier_atoms() == [:dark, :pulse, :ledger, :glass]
    end
  end

  describe "effective_tier/2" do
    test "resolves tier atoms and strings" do
      assert effective_tier(:dark, nil) == :dark
      assert effective_tier("pulse", nil) == :pulse
      assert effective_tier(:ledger, nil) == :ledger
      assert effective_tier("glass", nil) == :glass
    end

    test "clamps to the lower of the artifact tier and the viewer tier" do
      assert effective_tier(:glass, "pulse") == :pulse
      assert effective_tier(:ledger, :glass) == :ledger
      assert effective_tier(:ledger, %{tier: "dark"}) == :dark
      assert effective_tier(:glass, %{tier: :pulse}) == :pulse
    end

    test "a revoked artifact link is always dark" do
      revoked = %ArtifactLink{tier: "glass", revoked_at: DateTime.utc_now()}

      assert effective_tier(revoked, :glass) == :dark
      assert effective_tier(revoked, nil) == :dark
    end

    test "an unrevoked artifact link is clamped by the viewer" do
      link = %ArtifactLink{tier: "glass", revoked_at: nil}

      assert effective_tier(link, :ledger) == :ledger
      assert effective_tier(link, "pulse") == :pulse
      assert effective_tier(link, nil) == :glass
    end
  end

  describe "allows?/3" do
    test "metadata requires at least pulse" do
      refute allows?(:dark, :metadata, nil)
      assert allows?(:pulse, :metadata, nil)
      assert allows?(:ledger, :metadata, nil)
      assert allows?(:glass, :metadata, nil)
    end

    test "content requires at least ledger" do
      refute allows?(:pulse, :content, nil)
      assert allows?(:ledger, :content, nil)
      assert allows?(:glass, :content, nil)
    end

    test "full requires glass" do
      refute allows?(:ledger, :full, nil)
      assert allows?(:glass, :full, nil)
    end

    test "a lower viewer tier restricts the result" do
      refute allows?(:glass, :full, :ledger)
      refute allows?(:ledger, :content, :pulse)
      refute allows?(:glass, :metadata, :dark)
    end
  end

  describe "revoke/3" do
    test "sets revoked_at and a revocation tombstone" do
      link = %ArtifactLink{tier: "ledger"}
      revoker_id = Ecto.UUID.generate()

      changeset = revoke(link, "expired", revoker_id)

      assert %DateTime{} = get_field(changeset, :revoked_at)

      assert %{
               reason: "expired",
               revoked_by_id: ^revoker_id,
               revoked_at: _iso
             } = get_field(changeset, :revocation_tombstone)
    end
  end

  describe "viewer_tier/1" do
    test "recognizes admin maps, user accounts, and tier maps" do
      assert viewer_tier(%{admin: true}) == :glass
      assert viewer_tier(%{account_id: Ecto.UUID.generate()}) == nil
      assert viewer_tier(nil) == nil
      assert viewer_tier(:glass) == :glass
      assert viewer_tier("pulse") == :pulse
    end
  end

  describe "redact_for_viewer/3" do
    test "an owner sees detail, trace_ref, and trace_digest while a non-owner is redacted" do
      owner = repository_user_fixture("owner")
      other = repository_user_fixture("other")
      repository = repository_fixture()

      {:ok, link} =
        %ArtifactLink{}
        |> ArtifactLink.changeset(%{
          account_id: owner.id,
          repository_id: repository.id,
          artifact_type: "changelog",
          artifact_ref: "sha",
          tier: "dark"
        })
        |> Repo.insert()

      data = %{
        trace_ref: "trace:v1:owner",
        trace_digest: "sha256:owner",
        detail: %{"note" => "visible"}
      }

      redacted_owner = redact_for_viewer(data, link, owner)
      assert redacted_owner.trace_ref == "trace:v1:owner"
      assert redacted_owner.trace_digest == "sha256:owner"
      assert redacted_owner.detail == %{"note" => "visible"}

      redacted_other = redact_for_viewer(data, link, other)
      assert redacted_other.trace_ref == nil
      assert redacted_other.trace_digest == nil
      assert redacted_other.detail == %{}
    end
  end
end
