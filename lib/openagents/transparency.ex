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

  alias OpenAgents.Accounts
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
    if owner?(link, viewer) or admin?(viewer) do
      max_tier(:glass, link.tier)
    else
      clamp(tier_atom(link.tier), viewer)
    end
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

  @doc "The viewer's own transparency tier, used to clamp artifact disclosure."
  def viewer_tier(%{admin: true}), do: :glass

  def viewer_tier(%Accounts.User{} = user),
    do: if(Accounts.admin?(user), do: :glass, else: nil)

  def viewer_tier(%{tier: tier}), do: tier_atom(tier)
  def viewer_tier(%{account_id: _}), do: nil
  def viewer_tier(tier) when is_binary(tier), do: tier_atom(tier)
  def viewer_tier(tier) when is_atom(tier) and not is_nil(tier), do: tier_atom(tier)
  def viewer_tier(_), do: nil

  defp max_tier(a, b) do
    a_atom = tier_atom(a)
    b_atom = tier_atom(b)

    if @tier_rank[a_atom] >= @tier_rank[b_atom],
      do: a_atom,
      else: b_atom
  end

  defp owner?(%ArtifactLink{account_id: link_id}, %{account_id: viewer_id})
       when not is_nil(link_id) and not is_nil(viewer_id),
       do: link_id == viewer_id

  defp owner?(%ArtifactLink{account_id: link_id}, %Accounts.User{id: viewer_id})
       when not is_nil(link_id) and not is_nil(viewer_id),
       do: link_id == viewer_id

  defp owner?(_, _), do: false

  defp admin?(%{admin: true}), do: true
  defp admin?(%Accounts.User{} = user), do: Accounts.admin?(user)
  defp admin?(_), do: false

  defp clamp(tier, viewer) do
    case viewer_tier(viewer) do
      nil -> tier
      v -> if @tier_rank[v] < @tier_rank[tier], do: v, else: tier
    end
  end
end
