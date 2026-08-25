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
  * **Private data.** Two facts that only mean something together. The account
    export can be encrypted to a key the recipient holds (#178), and that is
    derived: `OpenAgentsWeb.DataController`'s compiled import table either
    reaches `OpenAgents.DataRights.Age` or it does not, so removing the
    encryption removes the claim in the same commit. The private store is not
    encrypted at rest, and that one is now derived too, from
    `OpenAgents.Forge.AtRest`: the store is encrypted exactly when no private
    column rests as plaintext, and the columns that do are named and proven
    plaintext against the database rather than asserted here. The derivation
    can only lower the claim, so an incomplete list understates the store
    instead of flattering it; #193 carries what is left.
    `operator_reads_source` is derived from the second fact rather than
    restated, because it is the same fact: the operator reads the plaintext an
    export is built from exactly while the store is plaintext. Publishing the
    encryption without it would let a reader conclude the operator cannot read
    an export, which is false.

  `degraded?` is true while any of the three falls short, so the page does not
  need a human to decide when to say so. It is expected to be true today.

  A fourth section says how much any of that is worth. Every claim above is
  derived from the running node, and the running node's code can be older than
  the ledger those claims answer to: #187 found the forge serving a revision 57
  commits behind `main`, where the export route, the chain, and this module
  itself did not exist, while every proof of them stayed green on `main`. A
  disclosure that cannot say how far its own code is from the code its proofs
  ran against is asking to be trusted on exactly the point it exists to remove,
  so `deployment` publishes that distance: the number of commits on the head
  this node serves that the running revision does not carry (#246).

  It is a distance and nothing else. Publishing the two revisions it lies
  between would put a commit sha on an anonymous surface, which `STATUS-001`
  keeps content-free and this section's own proof turns red for. It is also not
  an axis of `degraded?`: a node one commit behind is not less independent, and
  folding ordinary deploy lag into the independence verdict would make that
  verdict mean nothing on the day it mattered.

  Nothing here carries content: family names, counts, booleans, issue numbers,
  a ref name, and a document path. It answers with the same shape when the
  ledger is unreadable, so `STATUS-001`'s rule that the page renders during an
  incident still holds.
  """

  alias OpenAgents.DataRights.ExportInventory
  alias OpenAgents.Forge.Anchor
  alias OpenAgents.Forge.AtRest
  alias OpenAgents.Forge.Pushes
  alias OpenAgents.Forge.Repos

  @schema "openagents.forge_independence.v1"

  @anchor_issue 168
  @witness_issue 151
  @at_rest_issue 193
  @document "docs/forge-operator-independence.md"
  @export_encryption_module OpenAgents.DataRights.Age
  @export_controller OpenAgentsWeb.DataController
  @account_export OpenAgents.DataRights.AccountExport

  # The ref a candidate is proven against before it is pushed: `RELEASE-004`
  # binds the full local matrix to the exact candidate sha and
  # `.githooks/pre-push` refuses a push without it, so the head of this ref is
  # the newest revision the ledger's proofs have run against.
  @proven_ref "refs/heads/main"
  @sha ~r/\A[0-9a-f]{40}\z/

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
      "deployment" => deployment_section(),
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
      not verification["anchor_witnessed"] or
      not private_data["export_recipient_encryption"] or
      not private_data["encrypted_at_rest"]
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

  # `encrypted_at_rest` used to be the one stated value left here. It is now
  # derived from `OpenAgents.Forge.AtRest`, which answers it from the columns
  # that rest as plaintext rather than from a literal beside the disclosure. A
  # failed read answers `false`, the same direction every other gather fails
  # in: the store is claimed to be less protected than it is, never more.
  defp private_data_section do
    encrypted_at_rest? = safely(fn -> AtRest.encrypted_at_rest?() end) || false

    %{
      "export_recipient_encryption" => export_recipient_encryption?(),
      "encrypted_at_rest" => encrypted_at_rest?,
      "operator_reads_source" => not encrypted_at_rest?,
      "access_controlled" => access_controlled?(),
      "issue" => @at_rest_issue
    }
  end

  # The export route encrypts to a recipient-held key exactly while it calls
  # the module that does it. Reading the compiled import table is the same
  # technique `EXIT-002` and `EXIT-003` use to keep a structural claim from
  # decaying into a comment.
  defp export_recipient_encryption? do
    safely(fn -> @export_encryption_module in external_calls(@export_controller) end) || false
  end

  # "Takes the account and nothing else" is the whole access-control claim for
  # this export, and it is a fact about the function's shape.
  defp access_controlled? do
    safely(fn ->
      Code.ensure_loaded?(@account_export) and
        function_exported?(@account_export, :build, 1) and
        not function_exported?(@account_export, :build, 2)
    end) || false
  end

  # The same read `EXIT-002`'s and `EXIT-003`'s proofs perform: the callee set
  # a module was compiled with, which no comment or later refactor can flatter.
  defp external_calls(module) do
    case :beam_lib.chunks(:code.which(module), [:imports]) do
      {:ok, {^module, [imports: imports]}} -> Enum.map(imports, &elem(&1, 0))
      _unreadable -> []
    end
  end

  # How far the code answering all of the above is from the code the ledger's
  # proofs ran against. The forge hosts its own repository, so no outside
  # service is consulted: the running revision is the one this node reports as
  # deployed, the proven revision is the head of `refs/heads/main` in the bare
  # projection this node serves, and the distance between them is a `git`
  # count over objects already on disk.
  #
  # The claim is deliberately narrow. It is not "how far behind `main` this
  # forge is" — nothing here can see a `main` this node declines to serve. It
  # is "how many commits on the head this node serves the running revision does
  # not carry", which is exactly what the count establishes. A forge that will
  # not serve its own repository, a node whose bare projection is empty, and a
  # release built from a revision this forge never accepted all report `known:
  # false` and no distance, which is the same withholding `EXIT-005` and
  # `EXIT-006` already decline to detect.
  defp deployment_section, do: deployment(safely(&running_revision/0))

  @doc """
  The deployment section for a given running revision.

  Public with the revision as a parameter for the same reason `degraded?/3` is
  public: the node that runs this proof reports a build revision that is not a
  commit at all, so the projection alone can only ever exercise the branch that
  withholds. A proof that never sees a real distance cannot fail on the day one
  stops being computed.
  """
  @spec deployment(String.t() | nil) :: map()
  def deployment(revision) do
    behind = safely(fn -> commits_behind(revision) end)

    %{
      "proven_ref" => @proven_ref,
      "known" => is_integer(behind),
      "behind" => behind
    }
  end

  defp commits_behind(running) do
    with repo when is_binary(repo) <- List.first(Repos.allowed_repos()),
         storage_key = Pushes.mirror_storage_key(repo),
         true <- sha?(running),
         head when is_binary(head) <- Map.get(Repos.refs(storage_key), @proven_ref),
         true <- sha?(head) do
      count_between(storage_key, running, head)
    else
      _unknown -> nil
    end
  end

  # The same revision `/api/status` publishes for this node, so the distance
  # and the revision it is measured from can never describe different code.
  defp running_revision do
    OpenAgents.Forge.DeploymentNode.health()["revision"]
  end

  defp sha?(value), do: is_binary(value) and Regex.match?(@sha, value)

  # `running..head` counts commits reachable from the served head and not from
  # the running revision, which stays the right number when the running
  # revision is not an ancestor of it. A revision the bare projection has never
  # heard of fails the read, and a failed read claims nothing.
  defp count_between(storage_key, running, head) do
    case Repos.git(Repos.bare_path(storage_key), [
           "rev-list",
           "--count",
           "--end-of-options",
           running <> ".." <> head
         ]) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {behind, ""} -> behind
          _unparsed -> nil
        end

      _unreadable ->
        nil
    end
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
