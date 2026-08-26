defmodule OpenAgents.Memories.Promotions do
  @moduledoc """
  The drain from the memory store into the knowledge base, and the place the
  boundary between the two is enforced.

  ## The line, and where it is drawn

  Specification section 8 draws the line: the knowledge base owns what the
  project has reviewed and decided, memory owns what the network has observed
  and can evidence. A stance is editorial, a memory row is evidentiary. Two
  rules keep the two from becoming rival stores of one claim — promotion drains
  memory into the knowledge base, and the knowledge base wins a recall
  collision.

  The second rule needs a place to stand, and the cloud re-base took it away.
  The knowledge base is retrieved in the client, from a corpus compiled into a
  WebAssembly plugin; memory recall runs here, inside `POST /api/v1/responses`.
  The two notes are assembled in different processes and arrive in different
  parts of the request, so no process sees both.

  **This module is the enforcement point.** The boundary is drawn where a claim
  crosses it — at promotion — rather than at recall, and the reasoning is in
  `docs/memory/knowledge-base-boundary.md`. The short form:

  * A precedence rule needs a decidable notion of "the same claim". Two rails
    that retrieve by different methods over different corpora share no
    identifier unless somebody records one, and promotion is the only moment
    anybody does: a steward states that this row is now that stance.

  * Given that link, a recall-time rule would have nothing left to do. A
    promoted row is superseded, so it is not live; the tombstone that replaced
    it can never be admitted, so it is not eligible. Recall surfaces live
    admitted rows (specification 7.1), so a promoted claim's one live home is
    the stance, and there is no second speaker for the collision rule to
    silence.

  * For a pair no promotion links, no enforcement point could decide anything
    either. The client would have to judge "covers the same claim" by comparing
    a stance's prose to a memory's, which is a heuristic; shipping one as
    "the knowledge base wins" would read as a guarantee while dropping true
    memories on a false positive. Duplication is the benign failure and
    suppression is the destructive one, so the honest answer to a real duplicate
    is to promote it, which is what this module is for.

  ## What a promotion is

  `promote/3` is the existing correction path with a fixed shape. It writes a
  superseding row on the claim's slug — a **promotion tombstone** — and points
  the old row at it, so the store keeps the chain rather than deleting the
  claim. The tombstone carries:

  * `stance`, the knowledge-base stance id the claim now lives as. It is the
    `id` field of a record in the corpus at
    `plugins/knowledge-base/kb/stances.json` in `OpenAgentsInc/openagents`.
  * a body this module writes rather than the caller, naming that stance. The
    table requires the stance to appear in the body, so "a tombstone whose body
    names the stance" is a shape rather than a habit.
  * `evidence_refs` the steward cites for the promotion — where the stance
    lives and the digest of what was reviewed.
  * `admission: "candidate"`, which is all it can ever be. Nothing can admit a
    tombstone: the composite foreign key
    `(memory_id, memory_promoted) -> memories (id, promoted)` refuses an
    admission, a challenge, and a refutation alike.

  Only a steward promotes. Promotion records the outcome of a review, and the
  review is the knowledge base's authority; an author draining their own claim
  into the corpus would be asserting the review rather than recording it.

  ## What this module does not enforce

  Two things, both named rather than papered over.

  * **An unlinked coincidence.** A stance and an admitted system memory that a
    reader would call the same claim, with no promotion between them, both
    attach. Nothing here decides that, because nothing can decide it: the two
    rails share no identifier for the pair.

  * **A new claim written on a promoted slug.** After a promotion the slug's
    live head is a tombstone, and a steward who admits a fresh row on that slug
    is re-opening a claim the project already drained. Refusing it would take a
    read of `memories` by slug across accounts, which is the predicate
    MEMORY-010 exists to keep out of this store.
  """

  alias OpenAgents.Accounts.User
  alias OpenAgents.Memories.{Admissions, Memory}

  @tier "ledger"

  @doc """
  Promotes one system memory to a knowledge-base stance.

  Attributes: `stance` (required) — the stance id the claim now lives as — and
  `slug` (required) — the target's slug, which is what binds the tombstone to
  the claim it drains, exactly as `OpenAgents.Memories.Admissions.supersede/3`
  requires it. `evidence_refs` (required) cites where the stance lives and the
  digest of what was reviewed. `as_of` defaults to today, the date the claim
  became a reviewed position, and `entity` carries over from the claim when the
  caller names it.

  The body is not a caller's to write: `body/1` composes it so the stance is
  named the same way every time, and the table refuses a tombstone whose body
  does not name its stance.

  When the target is under open challenges, the same transaction records a
  refutation of each — a promotion is a steward's correction, and the
  correction is the resolution.

  Refuses `:steward_required` for an account without the role,
  `:stance_required` when no stance is named or the name is blank — there is
  nowhere for the claim to go, so there is no promotion to write — and
  `:not_supersedable` when the target is not a live system memory. A caller with no standing learns nothing
  about the row from any of them.
  """
  @spec promote(User.t(), String.t(), map()) ::
          {:ok, Memory.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :steward_required}
          | {:error, :stance_required}
          | {:error, :not_supersedable}
  def promote(%User{} = steward, memory_id, attrs) when is_map(attrs) do
    attrs = normalize(attrs)

    cond do
      not Admissions.steward?(steward) -> {:error, :steward_required}
      not named?(Map.get(attrs, "stance")) -> {:error, :stance_required}
      true -> Admissions.supersede(steward, memory_id, tombstone(attrs))
    end
  end

  # A blank stance is refused here rather than left to the changeset, which
  # casts an empty string to `nil` and would write an ordinary supersession
  # under a body announcing a promotion to nowhere.
  defp named?(stance) when is_binary(stance), do: String.trim(stance) != ""
  defp named?(_absent), do: false

  @doc """
  The body a promotion tombstone carries.

  Fixed rather than free text, so the stance is named identically on every
  tombstone and a reader who meets one knows where the claim went. The table
  requires the stance to appear here.
  """
  @spec body(String.t()) :: String.t()
  def body(stance) when is_binary(stance) do
    "Promoted to the OpenAgents knowledge base stance `#{stance}`. " <>
      "The reviewed stance is the live home for this claim; this row is a " <>
      "tombstone and surfaces to nobody."
  end

  @doc "The transparency tier every promotion tombstone carries."
  @spec tier() :: String.t()
  def tier, do: @tier

  # The tombstone's shape. Everything the caller may name is read from `attrs`;
  # everything that makes this a tombstone rather than a claim is put here, so a
  # request body cannot ask for a promotion that admits itself or for a body
  # that points somewhere other than the stance.
  defp tombstone(attrs) do
    stance = attrs |> Map.fetch!("stance") |> String.trim()

    attrs
    |> Map.take(["slug", "entity", "evidence_refs"])
    |> Map.merge(%{
      "stance" => stance,
      "body" => body(stance),
      "tier" => @tier,
      "admission" => "candidate",
      "as_of" => Map.get(attrs, "as_of") || Date.utc_today()
    })
  end

  defp normalize(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
