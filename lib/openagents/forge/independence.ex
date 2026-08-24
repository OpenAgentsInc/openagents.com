defmodule OpenAgents.Forge.Independence do
  @moduledoc """
  The public disclosure of how far this forge is from operator independence.

  `docs/forge-operator-independence.md` states the trust boundary honestly, and
  `EXIT-001` through `EXIT-005` bind the parts of it that are checkable. Both
  are read by someone who already went looking. This projection is the same
  statement placed where a person checking whether the forge is healthy will
  see it, because "one operator can read and rewrite everything, and here is
  what is not yet provable" is a fact about the service's condition in the same
  way a lagging mirror is.

  Three properties, and the honest answer to each is derived rather than
  restated, so a disclosure cannot drift away from the thing it describes:

  * **Export.** Counted from `OpenAgents.DataRights.ExportInventory`, the
    ledger `EXIT-001` enforces against the surface. A family that regresses to
    `:partial` or `:blocked` appears here without anyone editing this module,
    and a gap closed elsewhere disappears from here in the same commit.
  * **Verification.** `EXIT-002` and `EXIT-005` make a rewrite of the WAL
    evident and total, not impossible. That distinction survives only while a
    commitment exists somewhere the operator does not solely control, and
    publishing one and having one witnessed are two different facts, so both
    are published. `anchor_published` counts the anchors
    `OpenAgents.Forge.Anchor` has actually written rather than a config flag,
    so a publisher that has stopped reports `false`. `anchor_witnessed` is
    `false` because no party other than the operator attests to the document:
    the operator serves it and could serve any document, and its value is that
    a third party can cheaply keep a copy, not that anyone has. Issue #151
    carries the witness.
  * **Private data.** No export is encrypted to a key the recipient holds, and
    no Ecto column in this repository is encrypted at rest. Issue #178 carries
    that decision. This one is stated rather than derived, because there is no
    registry of encrypted columns to count and inventing one to make a number
    appear would be the kind of claim this disclosure exists to avoid.

  `degraded?` is true while any of the three falls short, so the page does not
  need a human to decide when to say so. It is expected to be true today.

  Nothing here carries content: family names, counts, booleans, issue numbers,
  and a document path. It answers with the same shape when the ledger is
  unreadable, so `STATUS-001`'s rule that the page renders during an incident
  still holds.
  """

  alias OpenAgents.DataRights.ExportInventory
  alias OpenAgents.Forge.Anchor

  @schema "openagents.forge_independence.v1"

  @anchor_issue 168
  @witness_issue 151
  @encryption_issue 178
  @document "docs/forge-operator-independence.md"

  @doc "The disclosure, in the shape `/api/status` publishes it."
  @spec projection() :: map()
  def projection do
    export = export_section()
    verification = verification_section()
    private_data = private_data_section()

    %{
      "schema" => @schema,
      "degraded" => degraded?(export, verification, private_data),
      "operator" => operator_section(),
      "export" => export,
      "verification" => verification,
      "private_data" => private_data,
      "document" => @document
    }
  end

  @doc "Whether the forge falls short of independence on any disclosed axis."
  @spec degraded?() :: boolean()
  def degraded?,
    do: degraded?(export_section(), verification_section(), private_data_section())

  @doc """
  Whether three given sections fall short on any axis.

  Public because two of the three axes are constants today: no export is
  encrypted and the anchor is witnessed by nobody, so `degraded?/0` would
  report `true` even if an axis were dropped from the disjunction entirely.
  Varying one section at a time is the only way a proof can show that each
  axis is actually load-bearing.
  """
  @spec degraded?(map(), map(), map()) :: boolean()
  def degraded?(export, verification, private_data) do
    export["gaps"] != [] or not verification["anchor_published"] or
      not verification["anchor_witnessed"] or not private_data["exports_encrypted"]
  end

  # Counted from the ledger, so this section cannot claim an export gap is
  # closed while `EXIT-001` still records it, and cannot invent one either.
  defp export_section do
    entries = safely(fn -> ExportInventory.entries() end) || []

    gaps =
      for entry <- entries, entry.status in [:partial, :blocked] do
        %{
          "family" => Atom.to_string(entry.family),
          "status" => Atom.to_string(entry.status),
          "issue" => entry.issue
        }
      end

    %{
      "families" => length(entries),
      "portable" => count(entries, :portable),
      "partial" => count(entries, :partial),
      "blocked" => count(entries, :blocked),
      "not_user_data" => count(entries, :not_user_data),
      "gaps" => Enum.sort_by(gaps, & &1["family"])
    }
  end

  defp count(entries, status), do: Enum.count(entries, &(&1.status == status))

  # Publishing an anchor and having one witnessed are two facts, and collapsing
  # them into one boolean is how a surface starts claiming more than it can
  # show. The operator serves the anchor document, so publication alone leaves
  # a consistent rewrite undetectable to anyone who kept no copy of it.
  #
  # The count comes from the anchors actually written, not from a config flag,
  # so a publisher that has stopped reports `false` without anyone editing
  # this module. A failed read answers `false` too: the failure direction
  # claims less than reality rather than more.
  defp verification_section do
    published? = safely(fn -> Anchor.published?() end) || false

    %{
      "property" => if(published?, do: "tamper_evident_published", else: "tamper_evident"),
      "chained" => true,
      "anchor_published" => published?,
      "anchor_witnessed" => false,
      "anchor" => Anchor.path(),
      "issue" => if(published?, do: @witness_issue, else: @anchor_issue)
    }
  end

  defp private_data_section do
    %{
      "exports_encrypted" => false,
      "encrypted_at_rest" => false,
      "access_controlled" => true,
      "issue" => @encryption_issue
    }
  end

  defp operator_section do
    %{
      "model" => "single_operator",
      "separation_of_duties" => false,
      "operator_reads_audited" => false,
      "mirror_is_authority" => false
    }
  end

  defp safely(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end
end
