defmodule OpenAgents.Memories.Admissions do
  @moduledoc """
  The gate in front of the system bucket, and the argument behind it: anyone
  can propose, only evidence admits, anyone may challenge, and only a steward
  resolves.

  ## Why every state is a record rather than a field

  A wrong `user` memory misleads one session. A wrong `system` memory would
  reach every session on the network, so the store treats a status the way the
  promise registry treats a green promise: it is derived from receipts somebody
  is answerable for, never read from a flag the claimant set. An author who
  writes `admission: "admitted"` on their own row has claimed something, and
  `status/1` still answers `"candidate"` until a steward records a verdict.

  The same reasoning carries to disagreement. A reader who finds an admitted
  claim wrong needs a path other than editing somebody else's row, so a
  challenge is a record, a refutation is a record, and a reversal is a further
  record. Nothing here updates anything, and the whole argument stays readable.

  ## The three roles

  * `record/3` writes an **admission**: a steward's verdict on a candidate.
  * `challenge/3` writes a **challenge**: any account's statement that an
    admitted claim is wrong, and the ground for saying so. A challenge that
    carries its own evidence is an *evidenced* challenge.
  * `refute/3` writes a **refutation**: a steward's resolution of one
    challenge, restoring the target.

  `supersede/3` is the other resolution path — a correction or a tombstone on
  the target's slug — and when a steward exercises it, it records a refutation
  of each open challenge on the target in the same transaction. That keeps the
  resolution a receipt rather than something a reader has to infer, and it
  keeps `status/1` a fold over records with no read of `memories` in it.

  ## How a status is derived

  These rules are the whole of it, and they are stated in precedence order.
  Every one of them reads the set of records; none of them reads the order the
  records were inserted in or the order a query happened to return them.

  1. **Admission first.** The effective verdict is the latest `admission`
     record by `{inserted_at, id}`, and a memory with no admission record
     behind it is a `candidate`. The `id` tie-break is what makes two records
     written in the same microsecond derive the same answer every time.
  2. **Only an admitted claim can be suspended.** A challenge against a
     candidate or a rejected memory is recorded and changes nothing: suspension
     means removal from recall, and neither of those is eligible for recall to
     begin with. Such a challenge also consumes none of its author's cap
     (rule 6), because it suspends nothing.
  3. **An open evidenced challenge suspends its target.** The status is
     `suspended`. This is the fail-safe direction: a contested claim silently
     absent is cheaper than a poisoned claim silently present. An *unevidenced*
     challenge is recorded and has no effect at all — that distinction is the
     one thing recall turns on, so an empty evidence list is refused at the
     table rather than read as absence.
  4. **A refutation resolves the challenge it names, and only that one.** A
     challenge is open when no refutation names it. Resolution is set
     membership, not a comparison of dates, which is what makes the derivation
     independent of arrival order: a refutation backfilled with an
     `inserted_at` earlier than its challenge still resolves it, and a second
     refutation of an already-resolved challenge changes nothing. A steward who
     changes their mind writes a **new challenge**; the refuted one stays
     refuted, and both stay readable.
  5. **Nothing else resolves a challenge.** A later admission record does not:
     re-admitting a suspended claim leaves it suspended, because the two
     resolution paths the specification names are a refutation and a
     superseding row, and a steward who means to restore a claim should have to
     say which challenge they are answering.
  6. **A challenge-flood cap bounds one account.** See below.

  Conflicts resolve the same way in every direction. Two verdicts on one
  candidate: the later one wins, ties broken by `id`. Two refutations of one
  challenge: the first closes it and the rest are no-ops. A challenge and a
  refutation written in either order: the same status, because neither rule
  above compares their timestamps.

  A superseded memory keeps whatever admission status its records derive.
  Supersession is not an admission state, it is a pointer at the row that
  replaced this one, and it is read where recall decides what to serve.

  ## What the flood cap actually bounds

  An account's open evidenced challenges suspend at most 25% of the
  admitted system store, rounded up, and beyond that they are recorded and
  queue with no recall effect. The challenges that take effect are the earliest
  by `{inserted_at, id}`, so the outcome is deterministic and equal inputs give
  equal outcomes. Several challenges by one account against the same memory
  count once: the bound is on memories suspended, not on records written.

  Two honest qualifications.

  This is **not** a defence against an attack. There is one server and no
  anonymous publisher, so there is no forged attribution and every challenger
  is an account the operator already accepts claims from. What the cap covers
  is the ordinary case: one prolific, or one systematically wrong, challenger
  should not be able to empty the store while a steward works through the
  queue.

  And it is a bound on the **store**, not on a per-message recall pool.
  Specification section 7.2 states the share against the ranked pool for a
  message, and no such pool exists yet — recall does not read this bucket. A
  share of the store does not imply the same share of every pool drawn from it,
  because an account's challenges can concentrate on one subject. The recall
  issue that builds the pool applies section 7.2's cap at ranking time; this
  one bounds what can be suspended at all.

  ## Who may write each record

  * **Admission** — a steward, and nobody else.
  * **Challenge** — any account, including the claim's own author. Challenging
    is the path for a reader with no standing to correct, so restricting it
    would remove the only reason the record exists.
  * **Refutation** — a steward, and nobody else. On this substrate that is an
    authorization check rather than a signature check: the server rejects the
    write on the role.
  * **Supersession** — the original author or a steward. Anyone else who
    disagrees files a challenge; the store has no path for editing somebody
    else's claim.

  The role is `OpenAgents.Accounts.admin?/1` — the operator allowlist of
  immutable GitHub numeric IDs, bootstrapped to the owner's account. That is
  the honest reading of "accounts the operator has marked as stewards,
  bootstrapped to the operator's own account", and it is the only account-level
  authority this server has: there is no `role` column on `users`, and the one
  per-account grant table in the repository grants roles on a repository rather
  than on the network. Broadening the steward set later touches the role
  assignment, not these record shapes. ADMIN-001 enumerates this module as an
  operator gate.

  The check runs before anything is read, so a refusal tells a caller with no
  standing nothing about the row they named. Role is never cast from a request
  body either: each changeset puts its own, so the challenge path cannot be
  talked into writing a refutation.

  ## What this module deliberately does not do

  It does not surface anything. An admitted system memory is stored, derived,
  and read by nobody: `OpenAgents.Memories.recall/3` reads the `user` and
  `learned` buckets only, and MEMORY-001 and MEMORY-010 confine recall to the
  acting account with no unscoped fallback. Reading an admitted row into every
  account's turn is cross-account recall by construction, so it is a privacy
  decision that belongs to the recall issue rather than a ranking detail this
  one can settle. A challenged memory nobody can see is still a coherent state:
  the point is that a wrong claim has a path other than editing someone else's
  row, and that a contested claim is marked so the eligibility filter has
  something to read when it arrives.

  It also never reads another account's memory. The composite foreign key
  `(memory_id, memory_bucket)` is what proves a target is a `system` row, so
  `record/3` and `challenge/3` write without a lookup; `refute/3` reads only
  `memory_admissions`, which is network-level rather than account-scoped, and
  the composite foreign key on `(challenge_id, memory_id, challenge_role)` is
  what actually holds a refutation to a challenge against the memory it
  restores. `supersede/3` authorizes inside the `UPDATE` predicate and learns
  nothing from a refusal.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OpenAgents.Accounts
  alias OpenAgents.Accounts.User
  alias OpenAgents.Memories
  alias OpenAgents.Memories.{Admission, Memory}
  alias OpenAgents.Repo

  # The share of the admitted store one account's open evidenced challenges may
  # suspend, as a percentage. Section 7.2's number, applied to the store
  # because there is no recall pool yet. See the module doc.
  @challenge_share 25

  @correction_ground "Resolved by a steward's correction on the target's slug."

  @doc """
  Whether `user` may admit, refute, and correct any system claim.

  A steward is an operator account. `admin?/1` refuses a banned account and
  reads the GitHub numeric ID rather than the login, so a renamed account keeps
  its authority and a transferred login does not inherit it.
  """
  @spec steward?(User.t() | nil) :: boolean()
  def steward?(user), do: Accounts.admin?(user)

  @doc "The percentage of the admitted store one account's challenges may suspend."
  @spec challenge_share() :: pos_integer()
  def challenge_share, do: @challenge_share

  @doc """
  How many admitted memories one account's open evidenced challenges may
  suspend, given `admitted` admitted memories in the store.

  Rounded up, so a store of one admitted claim can still have that claim
  challenged. An empty store has nothing to suspend and a cap of zero.
  """
  @spec challenge_cap(non_neg_integer()) :: non_neg_integer()
  def challenge_cap(admitted) when is_integer(admitted) and admitted >= 0 do
    div(admitted * @challenge_share + 99, 100)
  end

  @doc """
  Writes one admission record against a candidate system memory.

  Attributes: `verdict` (`admitted` or `rejected`) and `ground` (why). The
  steward and the candidate are set on the struct, so a request body can name
  neither.

  Refuses `:steward_required` for an account without the role, and
  `:not_found` when `memory_id` does not name a system memory — the composite
  foreign key decides that, so a caller learns nothing about a row in another
  bucket beyond the fact that it is not admissible.
  """
  @spec record(User.t(), String.t(), map()) ::
          {:ok, Admission.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :steward_required}
          | {:error, :not_found}
  def record(%User{} = steward, memory_id, attrs) when is_map(attrs) do
    if steward?(steward) do
      with {:ok, id} <- cast_id(memory_id) do
        %Admission{memory_id: id, author_id: steward.id}
        |> Admission.changeset(normalize(attrs))
        |> insert()
      end
    else
      {:error, :steward_required}
    end
  end

  @doc """
  Writes one challenge against a system memory.

  Attributes: `ground` (why the claim is wrong) and an optional
  `evidence_refs`. Carrying evidence is what makes this an evidenced challenge,
  and an evidenced challenge suspends an admitted target from recall until a
  steward resolves it. Without evidence the challenge is recorded and changes
  nothing — which is still worth writing, because it is on the record and a
  steward can read it.

  Any account may challenge, including the claim's own author. The target and
  the author are set on the struct, so a request body names neither, and
  `:not_found` covers both a target that is not a system memory and one that
  does not exist.
  """
  @spec challenge(User.t(), String.t(), map()) ::
          {:ok, Admission.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found}
  def challenge(%User{} = user, memory_id, attrs) when is_map(attrs) do
    with {:ok, id} <- cast_id(memory_id) do
      %Admission{memory_id: id, author_id: user.id}
      |> Admission.challenge_changeset(normalize(attrs))
      |> insert()
    end
  end

  @doc """
  Writes one refutation of a challenge, restoring its target.

  Attributes: `ground` (why the challenge does not stand). Only a steward may
  refute, and the check runs before the challenge is read, so an account
  without the role learns nothing about the challenge it named.

  A refutation resolves the one challenge it names. A target under two open
  challenges needs two refutations, which is the point: each ground was raised
  separately and each is answered separately.
  """
  @spec refute(User.t(), String.t(), map()) ::
          {:ok, Admission.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :steward_required}
          | {:error, :not_found}
  def refute(%User{} = steward, challenge_id, attrs) when is_map(attrs) do
    if steward?(steward) do
      with {:ok, id} <- cast_id(challenge_id),
           {:ok, challenged} <- fetch_challenge(id) do
        %Admission{
          memory_id: challenged.memory_id,
          author_id: steward.id,
          challenge_id: challenged.id
        }
        |> Admission.refutation_changeset(normalize(attrs))
        |> insert()
      end
    else
      {:error, :steward_required}
    end
  end

  @doc """
  A system memory's effective status: `candidate`, `admitted`, `rejected`, or
  `suspended`.

  Derived from the records that reference it, never from the candidate's own
  `admission` field. A memory with no record behind it is a `candidate`,
  whatever it says about itself. The precedence rules are in the module doc.

  Answers `nil` for a memory outside the system bucket, which has no admission
  status to have.
  """
  @spec status(Memory.t() | String.t()) :: String.t() | nil
  def status(%Memory{bucket: "system", id: id}), do: status(id)
  def status(%Memory{}), do: nil

  def status(memory_id) when is_binary(memory_id) do
    case cast_id(memory_id) do
      {:ok, id} -> Map.get(statuses(), id, "candidate")
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Every system memory some record names, and its derived status.

  The whole store at once, because the challenge cap is a property of the store
  rather than of one memory: how many of an account's challenges take effect
  depends on how many admitted claims there are and on which of that account's
  challenges came first. `status/1` reads one answer out of this.

  The system bucket is small by design — network-level claims, not per-account
  ones — so this reads the records rather than pushing the fold into SQL, where
  the ordering rules would be harder to see and no easier to trust. A memory
  with no record at all is absent here and is a `candidate`.
  """
  @spec statuses() :: %{optional(String.t()) => String.t()}
  def statuses do
    Repo.all(
      from(record in Admission,
        select: %{
          id: record.id,
          memory_id: record.memory_id,
          author_id: record.author_id,
          role: record.role,
          verdict: record.verdict,
          challenge_id: record.challenge_id,
          inserted_at: record.inserted_at,
          evidence: fragment("coalesce(jsonb_array_length(?), 0)", record.evidence_refs)
        }
      )
    )
    |> derive()
  end

  @doc """
  Every record against one system memory, oldest first.

  Append-only, so this is the whole argument rather than the current state:
  verdicts, challenges, and refutations together. `status/1` is what reads a
  state out of it.
  """
  @spec list(Memory.t() | String.t()) :: [Admission.t()]
  def list(%Memory{id: id}), do: list(id)

  def list(memory_id) when is_binary(memory_id) do
    case cast_id(memory_id) do
      {:ok, id} ->
        Repo.all(
          from(record in Admission,
            where: record.memory_id == ^id,
            order_by: [asc: record.inserted_at, asc: record.id]
          )
        )

      {:error, :not_found} ->
        []
    end
  end

  @doc """
  Corrects a system memory by writing a replacement and pointing the old row at
  it.

  Only the original author or a steward may correct a system slug. Anyone else
  who disagrees files a challenge; the store has no path for editing somebody
  else's claim, and supersession is the only correction path there is.

  `attrs` describe the replacement, which is written under `user`'s account
  through the ordinary write path — same evidence requirement, same tier floor,
  same constraint. Name the target's slug on it: the slug is what binds the
  correction to the claim it corrects. A correction is admitted at the account
  ceiling, as `OpenAgents.Memories.create/2` admits one, because it replaces a
  live row with a live row.

  When a **steward** corrects, the same transaction records a refutation of
  every open challenge on the target. That is the specification's second
  resolution path, and writing it down keeps the resolution a receipt rather
  than something a reader has to infer from a pointer. An author correcting
  their own claim resolves nothing: the challenges stand against the row that
  was wrong, and the replacement is a new claim with no challenges on it.

  The authorization is the `UPDATE` predicate rather than a read followed by a
  decision. A caller with no standing gets `:not_supersedable` and learns
  nothing about the row, including whether it exists.
  """
  @spec supersede(User.t(), String.t(), map()) ::
          {:ok, Memory.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_supersedable}
  def supersede(%User{} = user, target_id, attrs) when is_map(attrs) do
    with {:ok, id} <- cast_target(target_id) do
      replacement = Memories.build(user, Map.put(normalize(attrs), "bucket", "system"))

      Multi.new()
      |> Multi.insert(:replacement, replacement)
      |> Multi.run(:target, fn repo, %{replacement: written} ->
        updates = [superseded_by_id: written.id, updated_at: DateTime.utc_now()]

        case repo.update_all(correctable(user, id), set: updates) do
          {1, _rows} -> {:ok, written}
          {0, _rows} -> {:error, :not_supersedable}
        end
      end)
      |> Multi.run(:resolutions, fn repo, _changes -> resolve_by_correction(repo, user, id) end)
      |> Repo.transaction()
      |> case do
        {:ok, %{replacement: written}} -> {:ok, written}
        {:error, :replacement, changeset, _changes} -> {:error, changeset}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  # ── writing ────────────────────────────────────────────────────────────────

  defp insert(changeset) do
    case Repo.insert(changeset) do
      {:ok, written} -> {:ok, written}
      {:error, refused} -> refusal(refused)
    end
  end

  # The steward's correction is itself the resolution, so it leaves one
  # refutation per open challenge behind it. Unevidenced challenges are
  # resolved too: the correction answers the ground whether or not the ground
  # arrived with evidence, and leaving one open would mean the argument reads
  # as unfinished after it was settled.
  defp resolve_by_correction(repo, %User{} = user, target_id) do
    if steward?(user) do
      target_id
      |> open_challenges()
      |> repo.all()
      |> Enum.reduce_while({:ok, []}, fn challenge, {:ok, written} ->
        %Admission{memory_id: target_id, author_id: user.id, challenge_id: challenge.id}
        |> Admission.refutation_changeset(%{"ground" => @correction_ground})
        |> repo.insert()
        |> case do
          {:ok, refutation} -> {:cont, {:ok, [refutation | written]}}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
    else
      {:ok, []}
    end
  end

  # ── reading ────────────────────────────────────────────────────────────────

  # Only `memory_admissions`, and only the id: the record table is
  # network-level rather than account-scoped, and this crosses no account
  # boundary. A refutation still has to survive the composite foreign key,
  # which is what actually binds it to a challenge against this memory.
  defp fetch_challenge(id) do
    query =
      from(record in Admission,
        where: record.id == ^id,
        where: record.role == "challenge",
        select: %{id: record.id, memory_id: record.memory_id}
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      challenged -> {:ok, challenged}
    end
  end

  defp open_challenges(target_id) do
    resolved =
      from(record in Admission, where: record.role == "refutation", select: record.challenge_id)

    from(record in Admission,
      where: record.memory_id == ^target_id,
      where: record.role == "challenge",
      where: record.id not in subquery(resolved),
      select: %{id: record.id}
    )
  end

  # MEMORY-010: the account boundary is a predicate in the query. Here it is
  # one half of the authorization — the row is the actor's own — and the other
  # half is the steward role, which lives in the operator allowlist rather than
  # in a column and so arrives as a bound boolean. A caller who is neither
  # matches no row, so the update reports zero and nothing is read out.
  defp correctable(%User{id: user_id} = user, target_id) do
    steward = steward?(user)

    from(memory in Memory,
      where: memory.id == ^target_id,
      where: memory.bucket == "system",
      where: is_nil(memory.superseded_by_id),
      where: memory.user_id == ^user_id or type(^steward, :boolean)
    )
  end

  # ── derivation ─────────────────────────────────────────────────────────────

  # The rules in the module doc, in precedence order. Every ordering below is
  # over `{inserted_at, id}`, which is data on the records themselves, so the
  # same set of records derives the same statuses whatever order they arrived
  # or were read in.
  defp derive(records) do
    verdicts = verdicts(records)
    admitted = for {id, "admitted"} <- verdicts, into: MapSet.new(), do: id
    suspended = suspensions(records, admitted)

    Map.new(verdicts, fn {memory_id, verdict} ->
      if verdict == "admitted" and MapSet.member?(suspended, memory_id) do
        {memory_id, "suspended"}
      else
        {memory_id, verdict}
      end
    end)
  end

  # Rule 1. The latest verdict per memory. A memory with challenges but no
  # verdict is absent from this map and reads as a candidate.
  defp verdicts(records) do
    records
    |> Enum.filter(&(&1.role == "admission"))
    |> Enum.group_by(& &1.memory_id)
    |> Map.new(fn {memory_id, written} ->
      {memory_id, written |> Enum.max_by(&key/1) |> Map.fetch!(:verdict)}
    end)
  end

  # Rules 2 through 6. An open evidenced challenge against an admitted memory
  # suspends it, up to the cap on its author.
  defp suspensions(records, admitted) do
    resolved =
      for %{role: "refutation", challenge_id: id} <- records,
          is_binary(id),
          into: MapSet.new(),
          do: id

    cap = challenge_cap(MapSet.size(admitted))

    records
    |> Enum.filter(fn record ->
      record.role == "challenge" and record.evidence > 0 and
        not MapSet.member?(resolved, record.id) and
        MapSet.member?(admitted, record.memory_id)
    end)
    |> Enum.group_by(& &1.author_id)
    |> Enum.flat_map(fn {_author, challenges} -> effective(challenges, cap) end)
    |> MapSet.new()
  end

  # One account's share. Several challenges against the same memory count once,
  # because the bound is on memories suspended rather than on records written,
  # and the earliest of them is the one that dates the suspension.
  defp effective(challenges, cap) do
    challenges
    |> Enum.group_by(& &1.memory_id)
    |> Enum.map(fn {_memory_id, written} -> Enum.min_by(written, &key/1) end)
    |> Enum.sort_by(&key/1)
    |> Enum.take(cap)
    |> Enum.map(& &1.memory_id)
  end

  # The total order every rule sorts by. `inserted_at` is compared as an
  # integer rather than as a `DateTime` struct, because Erlang term order over
  # a struct compares its keys alphabetically — `day` before `month` before
  # `year` — which is not time. `id` breaks a tie, so two records written in
  # the same microsecond still derive one answer.
  defp key(record), do: {DateTime.to_unix(record.inserted_at, :microsecond), record.id}

  # ── refusals ───────────────────────────────────────────────────────────────

  # The composite foreign keys are what refuse a target outside the system
  # bucket and a refutation naming something that is not a challenge against
  # this memory, so their violations are reported as absence rather than as a
  # changeset error about a column the caller never named.
  defp refusal(changeset) do
    if Enum.any?(changeset.errors, fn {field, _error} ->
         field in [:memory_id, :challenge_id]
       end) do
      {:error, :not_found}
    else
      {:error, changeset}
    end
  end

  defp cast_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp cast_id(_value), do: {:error, :not_found}

  defp cast_target(value) do
    case cast_id(value) do
      {:ok, id} -> {:ok, id}
      {:error, :not_found} -> {:error, :not_supersedable}
    end
  end

  defp normalize(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
