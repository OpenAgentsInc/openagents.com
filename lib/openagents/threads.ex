defmodule OpenAgents.Threads do
  @moduledoc """
  Account-scoped threads and the model authority bound to them.

  A thread is the unit of agent work: one objective, its turns, its transcript,
  and its budget (`docs/taxonomy.md`). It is plural and disposable, and it
  requires no conversation. The account still has exactly one conversation
  (DATA-002); a thread is not one, and nothing here creates or reads one.

  ## The fence

  `OpenAgents.Inference.revoke_active_for_conversation/1` was documented as the
  generation fence and had no caller, so the fence it described never ran. A
  thread's fence is therefore stated as behavior with a caller rather than as a
  function nothing invokes:

  1. **Authority is singular.** `mint_grant/1` revokes every active grant for
     the thread and bumps `generation` in the same transaction as the mint, so
     a thread has at most one live grant and an older generation's token is
     provably stale. A partial unique index enforces the same property in
     PostgreSQL, so a concurrent mint cannot produce two.
  2. **Authority cannot outlive the thread.** `finish/2` and `cancel/2` revoke
     the thread's active grants inside the transaction that writes the terminal
     row, and `mint_grant/1` refuses a thread that is not open. A terminal
     thread therefore has no active grant, ever.
  3. **Authority dies with the record.** `inference_grants.thread_id` cascades
     on delete, so removing a thread — or the account under DATA-004 — removes
     its authority with it.

  ## The ceiling

  4. **Authority is capped.** `open/3` refuses an account that already holds
     `maximum_open_threads_per_account` open threads, reading the limit from
     `config/config.exs` next to the Box lane's
     `maximum_active_boxes_per_owner`. A token that can open one thread could
     otherwise open unbounded threads and spend without a ceiling. Because a
     thread has at most one live grant, capping open threads caps the account's
     concurrent thread-scoped authority by the same number. The count is taken
     under the owner visitor row's `FOR UPDATE` lock, inside the transaction
     that inserts, so two simultaneous opens at the boundary admit one thread,
     not two — the cap is what makes the account's joint credit exposure a
     bounded figure, so it has to hold under concurrency (issue #195).
  5. **The ceiling is self-clearing.** `reap_expired/1` runs at admission and
     on every read: an active grant whose clock has run out becomes `expired`,
     and the open thread it fenced becomes `failed` with `authority_expired`.
     Expiry therefore releases both the thread's active-grant slot and the
     account's admission slot without anyone asking, so an abandoned thread
     cannot lock an account out of its own ceiling.

  ## The audience

  6. **A transcript is private until its owner says otherwise.** A thread
     carries a transparency tier from the shared `dark/pulse/ledger/glass`
     vocabulary (`OpenAgents.Transparency`, `docs/taxonomy.md`), defaulting to
     `dark` — the account that opened it and nobody else. `open/3` accepts a
     wider tier and records `thread.visibility_set` in the transcript when one
     is given, so widening is an act with a record rather than a column that
     drifted. `fetch_readable/2` is the only read that a wider tier reaches;
     every write stays on `get_for_user/2`, because publishing a transcript for
     reading is not handing anyone the thread's authority (THREAD-002).

  A thread's ceilings are its own: `ceilings/0` reads the `thread_grant_*`
  settings and passes them to `OpenAgents.Inference.mint/1`, which otherwise
  applies the delegation ceilings. A delegation is one probe run the server
  admitted before it minted anything; a thread is authority a caller asked for,
  so the two budgets are stated separately and neither moves the other.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OpenAgents.Accounts.User
  alias OpenAgents.Chat.OpenRouter
  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Inference
  alias OpenAgents.Inference.{Credit, Grant, Models}
  alias OpenAgents.Repo
  alias OpenAgents.Threads.Event
  alias OpenAgents.Threads.Thread

  @maximum_listed 50
  @default_reasoning "high"
  @default_permission_profile "read_only"

  @doc """
  Open a thread for an account.

  The owner visitor is resolved (and created if absent) without touching the
  account's conversation. The admitted execution shape defaults to
  `OpenAgents.Inference.Models.default_id/0`, `high` reasoning, and the
  `read_only` permission profile; a caller may narrow or widen only within the
  admitted vocabulary. The thread's model is the model its grant pins, so a
  caller that opens a thread on `ox-alpha` gets authority for `ox-alpha`.

  Admission is where the ceiling lives. Elapsed authority is reaped first, so a
  slot held by an abandoned thread is released before the count is taken, and
  an account already at `maximum_open_per_account/0` is refused with
  `:thread_quota_reached` rather than given a further grant.

  `:visibility` is the thread's transparency tier and defaults to
  `OpenAgents.Threads.Thread.default_visibility/0`, owner-only. A wider tier
  given here is recorded in the transcript as `thread.visibility_set`
  (THREAD-002).
  """
  @spec open(User.t() | Visitor.t(), String.t(), keyword()) ::
          {:ok, Thread.t()} | {:error, :thread_quota_reached | Ecto.Changeset.t()}
  def open(owner, objective, options \\ [])

  def open(%User{} = user, objective, options) do
    user |> Conversations.ensure_owner_visitor() |> open(objective, options)
  end

  def open(%Visitor{id: visitor_id} = owner, objective, options) when is_binary(objective) do
    _reaped = reap_expired(owner)
    insert_thread(visitor_id, objective, options)
  end

  @doc """
  Open a thread and mint its authority, or leave nothing behind.

  This is the atom of work the public route performs. A thread that cannot hold
  authority is not a thread anyone can work, so a failed mint cancels the
  thread it opened rather than leaving an empty one holding an admission slot.
  """
  @spec open_and_mint(User.t() | Visitor.t(), String.t(), keyword()) ::
          {:ok, Thread.t(), Grant.t(), String.t()}
          | {:error,
             :thread_quota_reached | :thread_terminal | :credit_exhausted | Ecto.Changeset.t()}
  def open_and_mint(owner, objective, options \\ []) do
    with {:ok, thread} <- open(owner, objective, options) do
      case mint_grant(thread) do
        {:ok, fenced, grant, token} ->
          {:ok, fenced, grant, token}

        {:error, reason} ->
          _cancelled = cancel(thread, "The thread could not be granted model authority.")
          {:error, reason}
      end
    end
  end

  @doc "The reasoning effort a thread takes when its caller names none."
  @spec default_reasoning() :: String.t()
  def default_reasoning, do: @default_reasoning

  @doc "The permission profile a thread takes when its caller names none."
  @spec default_permission_profile() :: String.t()
  def default_permission_profile, do: @default_permission_profile

  defp insert_thread(visitor_id, objective, options) do
    now = DateTime.utc_now()

    attributes = %{
      objective: objective,
      repository: Keyword.get(options, :repository),
      visibility: Keyword.get(options, :visibility) || Thread.default_visibility(),
      model: Keyword.get(options, :model) || Models.default_id(),
      reasoning_effort:
        OpenRouter.reasoning_effort(Keyword.get(options, :reasoning, @default_reasoning)),
      permission_profile: Keyword.get(options, :permission_profile, @default_permission_profile)
    }

    Multi.new()
    |> Multi.run(:admission, fn repo, _changes ->
      # The cap is checked under the owner row's lock, inside the transaction
      # that inserts, so two simultaneous opens serialize here: the second
      # waits, counts the first's committed row, and is refused. A count read
      # outside the transaction could pass twice at the boundary and leave
      # nine open threads behind an eight-thread promise (issue #195).
      _serialized = lock_owner(repo, visitor_id)

      if open_count(visitor_id) >= maximum_open_per_account() do
        {:error, :thread_quota_reached}
      else
        {:ok, :admitted}
      end
    end)
    |> Multi.insert(:thread, Thread.open_changeset(attributes, visitor_id, now))
    |> Multi.run(:opened_event, fn _repo, %{thread: thread} ->
      insert_event(
        thread,
        "thread.opened",
        %{"objective_bytes" => byte_size(objective), "visibility" => thread.visibility},
        now
      )
    end)
    # Widening is an act, so it leaves a record rather than only a column value
    # (THREAD-002). The event is written only when the opener asked for a tier
    # wider than owner-only: a default thread was never widened, and an event
    # saying so on every open would make the record meaningless.
    |> Multi.run(:widened_event, fn _repo, %{thread: thread} ->
      if Thread.wide?(thread) do
        insert_event(
          thread,
          "thread.visibility_set",
          %{"visibility" => thread.visibility, "from" => Thread.default_visibility()},
          now
        )
      else
        {:ok, nil}
      end
    end)
    |> Multi.update(:counted, fn %{thread: thread, widened_event: widened} ->
      appended = if widened, do: 2, else: 1
      Thread.event_count_changeset(thread, thread.event_count + appended)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{counted: thread}} -> {:ok, thread}
      {:error, :admission, :thread_quota_reached, _changes} -> {:error, :thread_quota_reached}
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
    end
  end

  @doc "A thread owned by this account, or `nil` for anybody else's id."
  @spec get_for_user(User.t(), String.t()) :: Thread.t() | nil
  def get_for_user(%User{id: user_id}, thread_id) when is_binary(thread_id) do
    case Ecto.UUID.cast(thread_id) do
      {:ok, thread_id} ->
        from(t in Thread,
          join: v in Visitor,
          on: v.id == t.owner_visitor_id,
          where: t.id == ^thread_id and v.user_id == ^user_id
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  def get_for_user(_user, _thread_id), do: nil

  @doc """
  A thread this account may **read**, and whether it is the account's own.

  Reading is the only thing a transparency tier widens. Every other verb —
  appending to the transcript, cancelling the thread, re-minting its
  authority — stays on `get_for_user/2`, because a thread its owner published
  for reading is not a thread a stranger may write to or spend.

  Returns `{:ok, thread, :owner}` for the account's own thread, `{:ok, thread,
  :reader}` for somebody else's thread at a tier that admits this reader, and
  `:error` otherwise. The two cases are distinguished at the query rather than
  by a second read, so a caller that must withhold the owner's budget from a
  reader has the fact without asking again.

  The audience of a wide tier is *any signed-in account holding the thread's
  id*: both surfaces that call this — `GET /api/v3/threads/{thread_id}` and
  `/threads/:id` — require an authenticated principal, and this function does
  not invent an anonymous one (THREAD-002).
  """
  @spec fetch_readable(User.t(), String.t()) :: {:ok, Thread.t(), :owner | :reader} | :error
  def fetch_readable(%User{id: user_id}, thread_id) when is_binary(thread_id) do
    wide = Thread.wide_visibilities()

    with {:ok, id} <- Ecto.UUID.cast(thread_id),
         {%Thread{} = thread, owner_user_id} <-
           Repo.one(
             from(t in Thread,
               join: v in Visitor,
               on: v.id == t.owner_visitor_id,
               where: t.id == ^id,
               where: v.user_id == ^user_id or t.visibility in ^wide,
               select: {t, v.user_id}
             )
           ) do
      {:ok, thread, if(owner_user_id == user_id, do: :owner, else: :reader)}
    else
      _unreadable -> :error
    end
  end

  def fetch_readable(_user, _thread_id), do: :error

  @doc """
  The account's threads, newest first, bounded.

  `:repository` narrows the listing to threads recorded against exactly that
  repository string — an exact match on a bounded field the opener wrote, not a
  search. A resume picker filters here rather than parsing objectives.
  """
  @spec list_for_user(User.t(), keyword()) :: [Thread.t()]
  def list_for_user(%User{id: user_id}, options \\ []) do
    limit = options |> Keyword.get(:limit, @maximum_listed) |> min(@maximum_listed) |> max(1)

    from(t in Thread,
      join: v in Visitor,
      on: v.id == t.owner_visitor_id,
      where: v.user_id == ^user_id,
      order_by: [desc: t.inserted_at, desc: t.id],
      limit: ^limit
    )
    |> in_repository(Keyword.get(options, :repository))
    |> Repo.all()
  end

  defp in_repository(query, repository) when is_binary(repository),
    do: from(t in query, where: t.repository == ^repository)

  defp in_repository(query, _absent), do: query

  @doc """
  The thread's transcript, oldest first, bounded.

  `:after` continues from an event id already read. Without it a transcript
  longer than the cap could not be read back at all, and a session's history is
  exactly the thing that outgrows a cap: a working session records a turn and
  every tool it ran, which passes fifty inside an hour.
  """
  @spec list_events(Thread.t(), keyword()) :: [Event.t()]
  def list_events(%Thread{id: thread_id}, options \\ []) do
    limit = options |> Keyword.get(:limit, @maximum_listed) |> min(@maximum_listed) |> max(1)

    from(e in Event,
      where: e.thread_id == ^thread_id,
      order_by: [asc: e.id],
      limit: ^limit
    )
    |> after_event(Keyword.get(options, :after))
    |> Repo.all()
  end

  defp after_event(query, nil), do: query

  defp after_event(query, after_id) when is_integer(after_id),
    do: from(e in query, where: e.id > ^after_id)

  defp after_event(query, after_id) when is_binary(after_id) do
    case Integer.parse(after_id) do
      {id, ""} -> after_event(query, id)
      _unparsed -> query
    end
  end

  defp after_event(query, _other), do: query

  @doc """
  Append one bounded event to a thread's transcript and advance its counter.

  Refused on a terminal thread: a transcript that keeps growing after the
  report was written is not the transcript the report describes.

  A committed append is broadcast as `{:thread_event, event}` on the thread's
  topic (`subscribe/1`), after the transaction, so a subscriber never sees an
  event that rolled back.
  """
  @spec record_event(Thread.t(), String.t(), map()) ::
          {:ok, Thread.t()} | {:error, :thread_terminal | Ecto.Changeset.t()}
  def record_event(%Thread{} = thread, event_type, payload)
      when is_binary(event_type) and is_map(payload) do
    case record_events(thread, [%{event_type: event_type, payload: payload}]) do
      {:ok, updated, _events} -> {:ok, updated}
      {:error, {_index, %Ecto.Changeset{} = changeset}} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Append a batch of events to a thread's transcript, all or nothing.

  One transaction, insertion order preserved: either every entry lands, in the
  order given, or nothing does. A transcript with a hole in the middle
  describes a session that never happened, so one invalid entry rolls the whole
  batch back and the refusal names its position as `{index, changeset}`.

  The terminal refusal covers the whole batch for the same reason
  `record_event/3` refuses at all, and each committed event is broadcast as
  `{:thread_event, event}` in order after the transaction, exactly as a single
  append is, so a subscriber cannot tell a batch from the same events posted
  one at a time.

  The batch's size is the caller's to bound (`maximum_event_batch/0` is what
  the public route enforces); this function bounds only its shape.
  """
  @spec record_events(Thread.t(), [%{event_type: String.t(), payload: map()}]) ::
          {:ok, Thread.t(), [Event.t()]}
          | {:error,
             :thread_terminal | Ecto.Changeset.t() | {non_neg_integer(), Ecto.Changeset.t()}}
  def record_events(%Thread{} = thread, entries) when is_list(entries) and entries != [] do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      case locked(thread.id) do
        %Thread{status: "open"} = current ->
          with {:ok, events} <- insert_events(current, entries, now),
               {:ok, updated} <-
                 current
                 |> Thread.event_count_changeset(current.event_count + length(events))
                 |> Repo.update() do
            {updated, events}
          else
            {:error, reason} -> Repo.rollback(reason)
          end

        _terminal ->
          Repo.rollback(:thread_terminal)
      end
    end)
    |> case do
      {:ok, {updated, events}} ->
        for event <- events do
          Phoenix.PubSub.broadcast(OpenAgents.PubSub, topic(updated.id), {:thread_event, event})
        end

        {:ok, updated, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "How many events one batch append may carry."
  @spec maximum_event_batch() :: pos_integer()
  def maximum_event_batch, do: setting(:maximum_thread_event_batch, 100)

  defp insert_events(thread, entries, now) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, inserted} ->
      case insert_event(thread, entry.event_type, entry.payload, now) do
        {:ok, event} -> {:cont, {:ok, [event | inserted]}}
        {:error, changeset} -> {:halt, {:error, {index, changeset}}}
      end
    end)
    |> case do
      {:ok, inserted} -> {:ok, Enum.reverse(inserted)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Subscribe to a thread's transcript appends.

  Delivers `{:thread_event, %OpenAgents.Threads.Event{}}` for each committed
  append. Subscribe before reading the snapshot and dedup by the event id,
  which is monotonic per thread.
  """
  @spec subscribe(Thread.t() | String.t()) :: :ok | {:error, term()}
  def subscribe(%Thread{id: thread_id}), do: subscribe(thread_id)

  def subscribe(thread_id) when is_binary(thread_id) do
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, topic(thread_id))
  end

  defp topic(thread_id), do: "thread:" <> thread_id

  @doc """
  Mint model authority for a thread.

  The grant pins the thread's own model, so the model a caller was admitted to
  at `open/3` is the model every call on the thread reaches. A thread opened
  before models were admitted carries a vendor string rather than an admitted
  id; `OpenAgents.Inference.Models.fetch/1` resolves that spelling, and
  anything else it cannot route is refused rather than quietly replaced.

  This is the fence. In one transaction: the thread is locked and refused
  unless it is open, every active grant naming it is revoked, `generation` is
  bumped, and a fresh grant is minted against the thread — never against a
  conversation. Returns the plaintext token exactly once.
  """
  @spec mint_grant(Thread.t()) ::
          {:ok, Thread.t(), Grant.t(), String.t()}
          | {:error, :thread_terminal | :credit_exhausted | Ecto.Changeset.t()}
  def mint_grant(%Thread{} = thread) do
    Repo.transaction(fn ->
      case locked(thread.id) do
        %Thread{status: "open"} = current ->
          # Concurrent mints for one account serialize on the owner row
          # (locked after the thread row, always in that order), so each mint
          # reads the metered remainder at its own turn rather than from a
          # shared snapshot (issue #195). What the remainder deliberately does
          # not subtract is a live grant's unspent ceiling — see `ceilings/1`.
          _serialized = lock_owner(Repo, current.owner_visitor_id)
          _revoked = Inference.revoke_active_for_thread(current.id)

          with {:ok, fenced} <- current |> Thread.generation_changeset() |> Repo.update(),
               {:ok, ceilings} <- ceilings(fenced.owner_visitor_id),
               {:ok, grant, token} <-
                 Inference.mint(%{
                   owner_visitor_id: fenced.owner_visitor_id,
                   thread_id: fenced.id,
                   machine_id: nil,
                   model_id: fenced.model,
                   ceilings: ceilings
                 }) do
            {fenced, grant, token}
          else
            {:error, reason} -> Repo.rollback(reason)
          end

        _terminal ->
          Repo.rollback(:thread_terminal)
      end
    end)
    |> case do
      {:ok, {thread, grant, token}} -> {:ok, thread, grant, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  End a thread with its bounded report, revoking its authority in the same
  transaction. Idempotent refusal on an already-terminal thread.
  """
  @spec finish(Thread.t(), map()) ::
          {:ok, Thread.t()} | {:error, :thread_terminal | Ecto.Changeset.t()}
  def finish(%Thread{} = thread, result) when is_map(result) do
    report = Map.get(result, :report) || Map.get(result, "report") || ""

    attributes = %{
      status: Map.get(result, :status) || Map.get(result, "status") || "succeeded",
      report: report,
      report_digest: digest(report),
      usage: Map.get(result, :usage) || Map.get(result, "usage") || %{},
      error_code: Map.get(result, :error_code) || Map.get(result, "error_code"),
      completed_at: DateTime.utc_now()
    }

    terminate(thread, attributes)
  end

  @doc "Cancel a thread, revoking its authority in the same transaction."
  @spec cancel(Thread.t(), String.t()) ::
          {:ok, Thread.t()} | {:error, :thread_terminal | Ecto.Changeset.t()}
  def cancel(%Thread{} = thread, report \\ "The thread was cancelled before it reported.") do
    terminate(thread, %{
      status: "cancelled",
      report: report,
      report_digest: digest(report),
      error_code: "cancelled",
      completed_at: DateTime.utc_now()
    })
  end

  @doc """
  The ceilings a thread's grant is minted with.

  Read from `config/config.exs` and stated separately from the delegation
  ceilings in `OpenAgents.Inference`, because a thread's budget is not a
  delegation's budget. `GET /api/v3` publishes this map, so a client reads the
  budget it was given rather than discovering it by exhausting it.

  The cost figure here is the configured per-thread cap. What a particular
  thread is minted for is `ceilings/1`, which is this map with the cost lowered
  to what the account's credit has left.
  """
  @spec ceilings() :: Inference.ceilings()
  def ceilings do
    %{
      max_total_tokens: setting(:thread_grant_max_total_tokens, 1_000_000),
      max_calls: setting(:thread_grant_max_calls, 256),
      max_cost_microusd: setting(:thread_grant_max_cost_microusd, 2_000_000),
      ttl_seconds: setting(:thread_grant_ttl_seconds, 3_600)
    }
  end

  @doc """
  The ceilings this account's next thread is minted with.

  A thread spends the account's credit rather than a fresh allowance of its
  own, so the cost ceiling is what `OpenAgents.Inference.Credit.remaining/1`
  says is left — a signed-in account's whole balance is available to one thread
  if that is what the work needs. An account with nothing left is refused
  `:credit_exhausted` instead of being minted a grant it cannot spend.

  The remainder is metered spend, not minted ceilings: a live grant's unspent
  headroom is deliberately not subtracted, because a parent thread holds its
  whole remaining balance as ceiling and a delegated child thread opened while
  it runs must still be granted usable authority — reserving headroom would
  refuse every such child with `:credit_exhausted`. Two overlapping threads can
  therefore each be ceiled at the same remainder, whether opened concurrently
  or in sequence; `mint_grant/1` serializes concurrent mints on the owner row
  so each reads the remainder at its own turn, and the admission cap — itself
  serialized — bounds how many such ceilings can be live at once (issue #195,
  THREAD-001).
  """
  @spec ceilings(String.t()) :: {:ok, Inference.ceilings()} | {:error, :credit_exhausted}
  def ceilings(visitor_id) when is_binary(visitor_id) do
    case Credit.remaining(visitor_id) do
      0 -> {:error, :credit_exhausted}
      remaining -> {:ok, %{ceilings() | max_cost_microusd: remaining}}
    end
  end

  @doc "How many threads one account may hold open at once."
  @spec maximum_open_per_account() :: pos_integer()
  def maximum_open_per_account, do: setting(:maximum_open_threads_per_account, 8)

  @doc "How many threads this account currently holds open."
  @spec open_count(User.t() | Visitor.t() | String.t()) :: non_neg_integer()
  def open_count(%User{} = user), do: user |> Conversations.ensure_owner_visitor() |> open_count()
  def open_count(%Visitor{id: visitor_id}), do: open_count(visitor_id)

  def open_count(visitor_id) when is_binary(visitor_id) do
    Repo.one(
      from t in Thread,
        where: t.owner_visitor_id == ^visitor_id and t.status == "open",
        select: count(t.id)
    )
  end

  @doc """
  Retire the account's elapsed authority, and the threads it fenced.

  Expiry is a fact about a clock, not a request: a grant past `expires_at` is
  no longer authority whether or not anyone presents it. This transitions those
  grants to `expired`, and closes every open thread that has minted authority
  and no longer holds any, with `authority_expired`. Returns
  `{expired_grants, closed_threads}`.
  """
  @spec reap_expired(User.t() | Visitor.t()) :: {non_neg_integer(), non_neg_integer()}
  def reap_expired(%User{} = user),
    do: user |> Conversations.ensure_owner_visitor() |> reap_expired()

  def reap_expired(%Visitor{id: visitor_id}) do
    {expired, _} = Inference.expire_elapsed_for_owner(visitor_id)

    closed =
      visitor_id
      |> abandoned_thread_ids()
      |> Enum.count(fn thread_id ->
        match?({:ok, _closed}, terminate(%Thread{id: thread_id}, expired_attributes()))
      end)

    {expired, closed}
  end

  @doc """
  The most recent grant minted for this thread, whatever its status.

  A thread has at most one *active* grant (THREAD-001); a terminal thread has
  none, and its revoked grant is still the record of what was spent. A caller
  reading its usage needs that row, so this returns the newest grant rather
  than only a live one.
  """
  @spec latest_grant(Thread.t()) :: Grant.t() | nil
  def latest_grant(%Thread{id: thread_id}) do
    Repo.one(
      from g in Grant,
        where: g.thread_id == ^thread_id,
        order_by: [desc: g.inserted_at, desc: g.id],
        limit: 1
    )
  end

  @doc "Every active grant naming this thread. Empty for a terminal thread."
  @spec active_grants(Thread.t()) :: [Grant.t()]
  def active_grants(%Thread{id: thread_id}) do
    from(g in Grant, where: g.thread_id == ^thread_id and g.status == "active")
    |> Repo.all()
  end

  # ── internals ───────────────────────────────────────────────────────────

  defp terminate(%Thread{} = thread, attributes) do
    Repo.transaction(fn ->
      case locked(thread.id) do
        %Thread{status: "open"} = current ->
          _revoked = Inference.revoke_active_for_thread(current.id)

          case current |> Thread.terminal_changeset(attributes) |> Repo.update() do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end

        _terminal ->
          Repo.rollback(:thread_terminal)
      end
    end)
  end

  defp expired_attributes do
    report = "The thread's model authority expired before it reported."

    %{
      status: "failed",
      report: report,
      report_digest: digest(report),
      error_code: "authority_expired",
      completed_at: DateTime.utc_now()
    }
  end

  # An open thread that has minted authority and holds none is abandoned: the
  # only route that mints for a caller mints once, at open, so nothing is
  # coming to renew it.
  defp abandoned_thread_ids(visitor_id) do
    live =
      from(g in Grant,
        where: g.thread_id == parent_as(:thread).id and g.status == "active",
        select: 1
      )

    Repo.all(
      from t in Thread,
        as: :thread,
        where: t.owner_visitor_id == ^visitor_id,
        where: t.status == "open" and t.generation > 0,
        where: not exists(live),
        select: t.id
    )
  end

  defp setting(key, default), do: Application.get_env(:openagents, key, default)

  defp locked(thread_id) do
    Repo.one(from t in Thread, where: t.id == ^thread_id, lock: "FOR UPDATE")
  end

  # The serialization point for one account's admissions and mints. Lock order
  # is thread row first, owner row second, everywhere a transaction takes both,
  # so two writers cannot deadlock across the pair.
  defp lock_owner(repo, visitor_id) do
    repo.one(from v in Visitor, where: v.id == ^visitor_id, lock: "FOR UPDATE")
  end

  defp insert_event(%Thread{id: thread_id}, event_type, payload, now) do
    %Event{}
    |> Event.changeset(%{
      thread_id: thread_id,
      schema: Event.schema_version(),
      event_type: event_type,
      payload: payload,
      emitted_at: now
    })
    |> Repo.insert()
  end

  defp digest(report) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, report), case: :lower)
  end
end
