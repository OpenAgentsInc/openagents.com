defmodule OpenAgents.Transparency do
  @moduledoc """
  Context helpers for artifact transparency tiers.

  Tiers follow the same `dark/pulse/ledger/glass` naming used by the forge
  visibility levels:

    * `dark`   — nothing public
    * `pulse`  — metadata only
    * `ledger` — content and metadata
    * `glass`  — full access
  """

  import Ecto.Changeset

  alias OpenAgents.Transparency.ArtifactLink

  @tier_rank %{dark: 0, pulse: 1, ledger: 2, glass: 3}
  @tier_strings %{
    "dark" => :dark,
    "pulse" => :pulse,
    "ledger" => :ledger,
    "glass" => :glass
  }

  @capability_min %{
    metadata: :pulse,
    content: :ledger,
    full: :glass
  }

  @doc "All tier atoms, from least to most transparent."
  def tier_atoms, do: [:dark, :pulse, :ledger, :glass]

  @doc """
  The effective tier for `tier_or_link` given `viewer`.

  `viewer` may be a tier atom/string, a map with a `:tier` field, or `nil`.
  A revoked `ArtifactLink` always resolves to `:dark`.
  """
  def effective_tier(%ArtifactLink{revoked_at: nil} = link, viewer) do
    clamp(tier_atom(link.tier), viewer)
  end

  def effective_tier(%ArtifactLink{}, _viewer), do: :dark
  def effective_tier(tier, viewer), do: clamp(tier_atom(tier), viewer)

  @doc """
  Whether `tier_or_link` admits `capability` for `viewer`.

  Capabilities are `:metadata`, `:content`, and `:full`.
  """
  def allows?(tier, capability, viewer) do
    effective = effective_tier(tier, viewer)
    required = Map.get(@capability_min, capability, :dark)
    @tier_rank[effective] >= @tier_rank[required]
  end

  @doc """
  Returns `data` with `trace_ref`, `trace_digest`, and `detail` redacted
  according to the effective transparency tier.

  `data` must be a map with `trace_ref`, `trace_digest`, and `detail`.
  `artifact_tier_or_link` is an `ArtifactLink`, a tier atom/string, or `nil`.
  `viewer` is a tier atom/string, a map with a `:tier` field, or `nil`.
  """
  def redact_for_viewer(
        %{trace_ref: _, trace_digest: _, detail: _} = data,
        artifact_tier_or_link,
        viewer \\ nil
      ) do
    tier = artifact_tier_or_link || Map.get(data, :transparency_tier)

    %{
      data
      | trace_ref: if(allows?(tier, :metadata, viewer), do: data.trace_ref, else: nil),
        trace_digest: if(allows?(tier, :metadata, viewer), do: data.trace_digest, else: nil),
        detail: if(allows?(tier, :content, viewer), do: data.detail, else: %{})
    }
  end

  @doc """
  Marks `artifact_link` as revoked by `revoked_by_id` for `reason`.

  Returns a changeset with `revoked_at` and `revocation_tombstone` set.
  """
  def revoke(artifact_link, reason, revoked_by_id) do
    now = DateTime.utc_now()

    change(artifact_link)
    |> put_change(:revoked_at, now)
    |> put_change(:revocation_tombstone, %{
      reason: reason,
      revoked_by_id: revoked_by_id,
      revoked_at: DateTime.to_iso8601(now)
    })
  end

  defp tier_atom(tier) when is_atom(tier) do
    Map.get(@tier_strings, to_string(tier), :dark)
  end

  defp tier_atom(tier) when is_binary(tier) do
    Map.get(@tier_strings, tier, :dark)
  end

  defp tier_atom(_), do: :dark

  defp viewer_tier(%{tier: tier}), do: tier_atom(tier)
  defp viewer_tier(tier) when is_binary(tier), do: tier_atom(tier)
  defp viewer_tier(tier) when is_atom(tier) and not is_nil(tier), do: tier_atom(tier)
  defp viewer_tier(_), do: nil

  defp clamp(tier, viewer) do
    case viewer_tier(viewer) do
      nil -> tier
      v -> if @tier_rank[v] < @tier_rank[tier], do: v, else: tier
    end
  end
end
