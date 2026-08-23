defmodule OpenAgents.Transparency.ArtifactLinkTest do
  @moduledoc """
  Tests for `OpenAgents.Transparency.ArtifactLink` changeset validation.
  """

  use OpenAgents.DataCase, async: true

  alias OpenAgents.Transparency.ArtifactLink

  defp link_attrs(overrides) do
    Map.merge(
      %{
        account_id: Ecto.UUID.generate(),
        repository_id: Ecto.UUID.generate(),
        artifact_type: "changelog",
        artifact_ref: "sha",
        tier: "dark"
      },
      overrides
    )
  end

  describe "changeset/2" do
    test "accepts a valid transparency tier" do
      changeset = ArtifactLink.changeset(%ArtifactLink{}, link_attrs(%{tier: "glass"}))
      assert changeset.valid?
    end

    test "rejects an unrecognized transparency tier" do
      changeset = ArtifactLink.changeset(%ArtifactLink{}, link_attrs(%{tier: "invisible"}))

      assert "is invalid" in errors_on(changeset).tier
    end
  end
end
