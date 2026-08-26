defmodule OpenAgents.Memories.SystemRecall do
  @moduledoc """
  The one recall path that crosses an account boundary, and the two things that
  make crossing it defensible: an eligibility filter written as a database
  predicate, and per-source caps that bound how much of a note any one writer
  can own.

  ## What this widens, and why it is a decision rather than a detail

  Every other read in `OpenAgents.Memories` names `user_id`. That is
  MEMORY-001 and MEMORY-010: recall is confined to the acting account, with no
  unscoped fallback anywhere. The `system` bucket is the deliberate exception —
  a row one account wrote, admitted by a steward's receipt, read into every
  account's turn. That is the point of the bucket and it is also the sharpest
  thing about it, so this module exists to hold the exception in one place
  where it can be read, enumerated, and tested, rather than as a widened
  bucket list somewhere in the account's query.

  Two properties keep it bounded:

  * **The unscoped reads are enumerable.** The eligibility read below and the
    shared ranking query in `OpenAgents.Memories.Retrieval.Lexical` are the
    only two reads in either memory plane that name no account, both name the
    `system` bucket in place of one, and both are declared by module and by
    count in `test/openagents/memories_test.exs`. A third fails that test until
    somebody declares it on purpose.
  * **It is off unless an operator turns it on.** `enabled?/0` reads
    `:memory_recall, :system_bucket_enabled`, which is `false` in
    `config/config.exs` and declared `false` in the production and staging
    profiles. With it off nothing here issues a query, so `recall/3` behaves
    byte for byte as it did before this module existed.
  * **The eligibility filter replaces the scope predicate.** It is not an
    application-side filter over rows this module read anyway. What reaches
    `memories` is a query whose predicates are the bucket, liveness, the tier
    floor, and the set of ids a steward's records derived as `admitted`.

  ## The eligibility filter (specification section 7.1)

  A row surfaces only when all of these hold, and every one of them is a
  predicate in `pool_query/1`:

  * `bucket = 'system'` — the whole namespace, one query.
  * `superseded_by_id IS NULL` — a corrected claim is the correction, not both.
  * `tier IN ('ledger','glass')` — at or above `ledger`. A `dark` or `pulse`
    claim cannot ship its content, so it is not a system memory; the table
    refuses one outright, and the predicate is here as well because a floor
    stated in exactly one place is a floor that moves when that place does.
  * `id IN (…)` — the ids `OpenAgents.Memories.Admissions.statuses/0` derived
    as `admitted`. Candidates, rejected rows, and rows suspended by an open
    evidenced challenge are all absent from that set, so none of them reaches
    the query at all.

  The derived status is bound into the query rather than compared after it.
  Deriving it is a fold over `memory_admissions` — a network-level table with
  no account column — and the fold cannot be pushed into the `memories` query
  because the challenge-flood cap is a property of the whole record set rather
  than of one row. So the honest description is: one read derives the admitted
  set, and the `memories` read then names that set as a predicate. Nothing is
  filtered out of a result.

  A row's own `admission` column is read by nothing here. An author who writes
  `admitted` on their own row has claimed something, and the claim reaches no
  turn.

  ## Per-source caps (specification section 7.2)

  Admission is the gate on truth; the caps are the gate on volume. A writer who
  passes the first still cannot win a note by flooding.

  * **Per-pool:** at most 25% of the ranked candidate pool's slots come from
    one account, enforced by a stable round-robin over accounts in rank order.
    Accounts enter the rotation in the order of their best-ranked memory, and
    each contributes its own memories in rank order, so the pool is a spread of
    the store rather than the top of whichever account writes most.
  * **Per-note:** at most 1 memory per account and at most 2 in total actually
    attach, matching the knowledge-base note limit. Past two, more network
    claims are noise rather than context.

  This is the pool cap the store-level cap in `Admissions` deliberately did not
  imply. That one bounds how much of the admitted **store** one account's
  challenges can suspend; this one bounds how much of one message's **pool**
  one account's claims can occupy, and a share of the store does not imply the
  same share of a pool, because an account's writing can concentrate on one
  subject.

  ## Determinism

  Equal inputs give equal notes. The eligibility read is ordered
  `desc: inserted_at, desc: id`, which is total; ranking is
  `OpenAgents.Memories.Retrieval.order/2`, the same stable sort the account's
  own recall uses; and the round-robin walks accounts and memories in that
  order without consulting anything else. No step reads insertion order from
  the database, a map's traversal order, or the wall clock.

  ## It degrades to silence

  An empty store, an unreadable one, an unavailable ranking backend: each one
  recalls nothing. `pool/1` never raises, because a turn that cannot reach the
  network's memory is a turn without it, not a failed turn.
  """

  import Ecto.Query

  alias OpenAgents.Memories.{Admissions, Memory, Retrieval}
  alias OpenAgents.Repo

  # Specification section 7.2's numbers. They are constants rather than
  # configuration: they are the poisoning posture the design argues for, not a
  # dial an operator tunes per deployment.
  @pool_share 25
  @per_account_per_note 1
  @per_note 2

  # The tier floor from section 5.2. `ledger` means the body and metadata are
  # readable by every account, which is what recall does with them.
  @tiers ~w(ledger glass)

  @doc """
  Whether this deployment surfaces the system bucket at all.

  `false` in `config/config.exs` and in the production profile. Read it before
  anything else: with it off, no query in this module runs and recall is the
  account-scoped read it has always been.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: setting(:system_bucket_enabled, false) == true

  @doc "The tiers a system memory must carry to surface. The floor is `ledger`."
  @spec tiers() :: [String.t()]
  def tiers, do: @tiers

  @doc "The share of one message's ranked pool a single account may fill, as a percentage."
  @spec pool_share() :: pos_integer()
  def pool_share, do: @pool_share

  @doc """
  How many of `slots` one account may fill, rounded up.

  Rounded up so a pool of one or two candidates is not emptied by its own cap,
  and so the bound reads the same way `Admissions.challenge_cap/1` reads.
  """
  @spec pool_cap(non_neg_integer()) :: non_neg_integer()
  def pool_cap(slots) when is_integer(slots) and slots >= 0 do
    div(slots * @pool_share + 99, 100)
  end

  @doc "The most memories one account may put in a single note."
  @spec per_account_per_note() :: pos_integer()
  def per_account_per_note, do: @per_account_per_note

  @doc "The most system memories one note may carry in total."
  @spec per_note() :: pos_integer()
  def per_note, do: @per_note

  @doc """
  The ranked, capped candidate pool for `query`, highest first.

  Empty when the flag is off, when `query` is empty, and when nothing in the
  store is eligible. Each memory carries the status the admission records
  derived, on `derived_status`, so a note prints what a steward's receipts say
  rather than what the row claims about itself.
  """
  @spec pool(String.t()) :: [Memory.t()]
  def pool(query) when is_binary(query) and query != "" do
    if enabled?() do
      case eligible() do
        [] -> []
        candidates -> candidates |> rank(query) |> round_robin()
      end
    else
      []
    end
  rescue
    _error -> []
  end

  def pool(_query), do: []

  @doc """
  What one note attaches from `pool`, within `characters` of body text.

  The two caps of section 7.2's per-note half: one memory per account, two in
  total. The character budget is whatever the account's own memories left of
  MEMORY-010's per-turn ceiling, so the system bucket widens who a note can
  quote without widening how long a note can be.

  What the caps and the budget exclude is not reported. The account's own
  `dropped` count exists so a reader can see their store was larger than the
  turn; a count of network claims that did not fit would tell every account how
  big the shared store is, which is a fact about other accounts.
  """
  @spec attachable([Memory.t()], non_neg_integer()) :: [Memory.t()]
  def attachable(pool, characters) when is_list(pool) and is_integer(characters) do
    {kept, _seen, _left} =
      Enum.reduce(pool, {[], %{}, characters}, fn memory, {kept, seen, remaining} ->
        written = Map.get(seen, memory.user_id, 0)
        cost = String.length(memory.body)

        if length(kept) < @per_note and written < @per_account_per_note and cost <= remaining do
          {[memory | kept], Map.put(seen, memory.user_id, written + 1), remaining - cost}
        else
          {kept, seen, remaining}
        end
      end)

    Enum.reverse(kept)
  end

  # ── internal ───────────────────────────────────────────────────────────────

  # The eligibility filter, as one query. `admitted` is derived first because
  # the derivation is a fold over a table with no account column; what happens
  # here is that the derived set is named as a predicate rather than compared
  # to rows this read returned anyway.
  #
  # MEMORY-001: one of the two queries in the memory plane that name no
  # account, and these predicates are what stand in its place. The other is the
  # shared ranking query in `OpenAgents.Memories.Retrieval.Lexical`, which
  # names the bucket too and reads only the ids this one already narrowed.
  defp eligible do
    admitted = admitted_ids()

    if admitted == [] do
      []
    else
      admitted
      |> pool_query()
      |> Repo.all()
      |> Enum.map(&%{&1 | derived_status: "admitted"})
    end
  end

  # Named rather than inlined so the MEMORY-001 amendment has one query to
  # point at, and so a test can read this module's source and prove that the
  # predicates below are the ones standing in for `user_id`.
  defp pool_query(admitted) when is_list(admitted) do
    from(memory in Memory,
      where: memory.bucket == "system",
      where: is_nil(memory.superseded_by_id),
      where: memory.tier in ^@tiers,
      where: memory.id in ^admitted,
      order_by: [desc: memory.inserted_at, desc: memory.id],
      limit: ^maximum_pool()
    )
  end

  # Only `admitted`. `candidate`, `rejected`, and `suspended` are every other
  # value the derivation produces, and none of them surfaces.
  defp admitted_ids do
    for {id, "admitted"} <- Admissions.statuses(), do: id
  end

  # The same backend the account's recall runs on, and the same tie-breaks,
  # scored over a pool no account owns.
  defp rank(candidates, query) do
    {_backend, ranked} = Retrieval.rank_shared(query, candidates)
    ranked
  end

  # Section 7.2's per-pool cap. Accounts enter in the order of their
  # best-ranked memory and each contributes in its own rank order, one per
  # round, until the pool is full or every account is spent. A prolific account
  # therefore holds its share of the slots and no more, and an account with one
  # good memory is not pushed out by an account with forty mediocre ones.
  defp round_robin(ranked) do
    memories = Enum.map(ranked, fn {memory, _score} -> memory end)
    slots = min(length(memories), maximum_pool())
    cap = pool_cap(slots)

    accounts = memories |> Enum.map(& &1.user_id) |> Enum.uniq()
    by_account = Enum.group_by(memories, & &1.user_id)

    0..max(cap - 1, 0)
    |> Enum.flat_map(fn round ->
      Enum.flat_map(accounts, fn account ->
        case by_account |> Map.fetch!(account) |> Enum.at(round) do
          nil -> []
          memory -> [memory]
        end
      end)
    end)
    |> Enum.take(slots)
  end

  defp maximum_pool, do: setting(:maximum_system_pool, 40)

  # `|| []` rather than a `get_env/3` default: the key can be present and nil,
  # and a nil there would reach `Keyword.get/3` as a hard crash on a path whose
  # whole contract is to degrade.
  defp setting(key, fallback) do
    (Application.get_env(:openagents, :memory_recall) || [])
    |> Keyword.get(key, fallback)
  end
end
