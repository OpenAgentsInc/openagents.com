defmodule OpenAgents.Memories do
  @moduledoc """
  The account's memories: what it asked to have remembered, and what the server
  learned on its behalf.

  Memory lives where the account lives. This store is a table in this database,
  not a file on whichever machine happened to run the session, because the CLI,
  the web app, and the API are three clients of one account and a memory
  written through any of them belongs to all three.

  ## Why this is a plane of its own

  This repository already has memory planes, and a fourth one needs a reason
  rather than a preference. The reason is that both existing planes are scoped
  and sourced on axes this store cannot use.

  * **Scope.** `OpenAgents.ProfileMemory` and `OpenAgents.ExperienceMemory` are
    scoped to `OpenAgents.Conversations.Visitor` — a signed browser under the
    account's one canonical conversation (DATA-002). This lane authenticates an
    `OpenAgents.Accounts.User` over the API, and a CLI session has no browser to
    be a visitor of. Scoping here is `memories.user_id`, and MEMORY-010 makes
    that a database predicate rather than a filter someone remembered to write.

  * **Source.** A profile-memory record is only active with a same-owner
    complete user-message source or a host-recorded owner assertion
    (MEMORY-003), and its sources are `messages` rows in that one conversation.
    A memory written from a coding session comes out of a **thread**, and a
    thread is explicitly not a conversation (THREAD-001). There is no
    admissible profile-memory source for it.

  * **The `learned` bucket cannot live there at all.** MEMORY-002 says
    conversation evidence never enters the profile-memory plane through
    repetition, model confidence, or recall classification, and MEMORY-003 says
    candidates never activate through repetition or model confidence.
    Consolidation-derived memory is exactly that, so admitting it to profile
    memory would mean weakening two current invariants to fit a design.

  What this store is **not** is a second home for browser profile claims. A
  durable fact a reader states in the web conversation still belongs in
  `OpenAgents.ProfileMemory`, under its consent and correction contract. The
  two planes are expected to be reconciled once one scope can express the
  other; that is a decision with its own issue, not a thing to assume here.

  ## What it holds

  Two buckets, described on `OpenAgents.Memories.Memory`. `user` memories are
  explicit: a reader said "remember that I prefer X" and something called
  `create/2`. Nothing here infers a memory from what a turn contained, and
  nothing should — a store that fills itself is a store nobody trusts.
  `learned` memories come from server-side consolidation over thread events.

  ## Corrections supersede

  `create/2` accepts `supersedes`, and the replacement points the old row at
  itself rather than editing it. Recall reads live rows only, so the correction
  takes effect immediately, and the row it corrected stays readable through
  `list/2` with `include_superseded: true`. A wrong `learned` memory is traced
  through `source_ref` to the work that taught it and superseded from there.

  ## Recall is bounded three ways

  `recall/3` is what `POST /api/v1/responses` calls before the provider. It is
  bounded by the store (`maximum_live_memories` per account, enforced at
  write), by count (`maximum_attached` per turn), and by size
  (`maximum_attached_characters` per turn). Whatever the bounds exclude is
  counted into `OpenAgents.Memories.Recall`'s `dropped`, and the note says so —
  a memory that did not fit is reported, never truncated into a half sentence.

  The two buckets clear the bar differently, and the difference is the whole
  point of the feature:

  * A `user` memory attaches whenever the account has one. The reader asked for
    it; "remember I use pnpm, not npm" has to reach "install the deps", and
    those two sentences share no word.
  * A `learned` memory must clear the retrieval backend's floor. Consolidation
    writes these without being asked, so they earn attention by being about
    this turn rather than by existing.

  Retrieval itself is `OpenAgents.Memories.Retrieval`, which chooses between an
  embedding backend and a lexical stand-in.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OpenAgents.Accounts.User
  alias OpenAgents.Memories.{Memory, Recall, Retrieval}
  alias OpenAgents.Memories.Retrieval.Semantic
  alias OpenAgents.Repo

  @maximum_listed 200

  @doc """
  Writes one memory for `user`.

  Attributes: `body` (required), `bucket` (`user` by default), `source_ref`,
  and `supersedes` — the id of a memory this one replaces, which must belong to
  the same account and must still be live.

  The owner is set on the struct and never cast, so a request body cannot name
  whose memory it is writing.
  """
  @spec create(User.t(), map()) ::
          {:ok, Memory.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :quota_reached}
          | {:error, :supersedes_not_found}
  def create(%User{} = user, attrs) when is_map(attrs) do
    attrs = normalize(attrs)
    body = Map.get(attrs, "body")

    embedding =
      case body do
        text when is_binary(text) and text != "" -> Semantic.embedding_for(text)
        _absent -> nil
      end

    attrs =
      case embedding do
        {vector, model} -> Map.merge(attrs, %{"embedding" => vector, "embedding_model" => model})
        nil -> attrs
      end

    changeset = Memory.changeset(%Memory{user_id: user.id}, attrs)

    Multi.new()
    |> Multi.run(:supersedes, fn _repo, _changes -> superseded(user, attrs) end)
    |> Multi.run(:quota, fn _repo, changes -> quota(user, changes.supersedes) end)
    |> Multi.insert(:memory, changeset)
    |> Multi.run(:supersede, fn repo, changes -> link(repo, changes) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{memory: memory}} -> {:ok, memory}
      {:error, :memory, changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  The account's memories, newest first.

  Live only unless `include_superseded: true`. Options: `bucket` to narrow to
  one bucket, and `limit`, capped at #{@maximum_listed}.
  """
  @spec list(User.t(), keyword()) :: [Memory.t()]
  def list(%User{} = user, opts \\ []) do
    user
    |> scope(opts)
    |> order_by([memory], desc: memory.inserted_at, desc: memory.id)
    |> limit(^limit(opts))
    |> Repo.all()
  end

  @doc "One of the account's memories by id, live or superseded."
  @spec fetch(User.t(), String.t()) :: {:ok, Memory.t()} | {:error, :not_found}
  def fetch(%User{id: user_id}, id) when is_binary(id) do
    with {:ok, memory_id} <- Ecto.UUID.cast(id),
         %Memory{} = memory <- Repo.get_by(Memory, id: memory_id, user_id: user_id) do
      {:ok, memory}
    else
      _absent -> {:error, :not_found}
    end
  end

  def fetch(%User{}, _id), do: {:error, :not_found}

  @doc """
  Points `memory` at the memory that replaced it.

  Both must belong to the same account, and a memory cannot supersede itself.
  """
  @spec supersede(Memory.t(), Memory.t()) :: {:ok, Memory.t()} | {:error, :not_supersedable}
  def supersede(%Memory{user_id: owner} = memory, %Memory{user_id: owner} = replacement)
      when memory.id != replacement.id do
    memory
    |> Memory.supersede_changeset(replacement)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :not_supersedable}
    end
  end

  def supersede(%Memory{}, %Memory{}), do: {:error, :not_supersedable}

  @doc """
  Removes one memory outright.

  Deletion is deletion: unlike a correction, nothing is kept. A memory that
  points at this one as its replacement keeps its own row and loses the
  pointer, so removing a correction never removes the history behind it.
  """
  @spec delete(User.t(), String.t()) :: {:ok, Memory.t()} | {:error, :not_found}
  def delete(%User{} = user, id) do
    with {:ok, memory} <- fetch(user, id),
         {:ok, deleted} <- Repo.delete(memory) do
      {:ok, deleted}
    else
      _absent -> {:error, :not_found}
    end
  end

  @doc """
  What this turn should be told, bounded.

  `query` is the incoming input. Every live memory the account holds is ranked
  against it; `user` memories are kept regardless of score and `learned` ones
  only above the backend's floor; the result is cut to `maximum_attached`
  memories and `maximum_attached_characters`, and what the cut excluded is
  counted rather than dropped in silence.

  Never raises. An unreadable store or an unavailable backend recalls nothing.
  """
  @spec recall(User.t(), String.t(), keyword()) :: Recall.t()
  def recall(user, query, opts \\ [])

  def recall(%User{} = user, query, opts) when is_binary(query) and query != "" do
    candidates = list(user, limit: maximum_live_memories())
    {backend, ranked, floor} = Retrieval.rank(user.id, query, candidates)

    eligible =
      Enum.flat_map(ranked, fn {memory, score} ->
        if memory.bucket == "user" or score > floor, do: [memory], else: []
      end)

    {kept, dropped} = bound(eligible, opts)

    %Recall{memories: kept, dropped: dropped, backend: backend}
  rescue
    _error -> %Recall{memories: [], dropped: 0, backend: :lexical}
  end

  def recall(%User{}, _query, _opts),
    do: %Recall{memories: [], dropped: 0, backend: :lexical}

  @doc "The most live memories one account may hold."
  @spec maximum_live_memories() :: pos_integer()
  def maximum_live_memories, do: setting(:maximum_live_memories, 200)

  @doc "The most memories one turn may attach."
  @spec maximum_attached() :: pos_integer()
  def maximum_attached, do: setting(:maximum_attached, 8)

  @doc "The most characters of memory bodies one turn may attach."
  @spec maximum_attached_characters() :: pos_integer()
  def maximum_attached_characters, do: setting(:maximum_attached_characters, 2_000)

  # ── internal ───────────────────────────────────────────────────────────────

  # Count first, size second, and the count of what neither admitted. Taking
  # the highest-ranked memories until the character budget is spent keeps the
  # note about this turn rather than about whichever memory is longest.
  defp bound(memories, opts) do
    count = Keyword.get(opts, :maximum_attached, maximum_attached())
    characters = Keyword.get(opts, :maximum_attached_characters, maximum_attached_characters())

    {kept, _left} =
      memories
      |> Enum.take(count)
      |> Enum.reduce({[], characters}, fn memory, {kept, remaining} ->
        cost = String.length(memory.body)

        if cost <= remaining, do: {[memory | kept], remaining - cost}, else: {kept, remaining}
      end)

    kept = Enum.reverse(kept)
    {kept, length(memories) - length(kept)}
  end

  defp scope(%User{id: user_id}, opts) do
    query = from(memory in Memory, where: memory.user_id == ^user_id)

    query =
      if Keyword.get(opts, :include_superseded, false) do
        query
      else
        where(query, [memory], is_nil(memory.superseded_by_id))
      end

    case Keyword.get(opts, :bucket) do
      bucket when bucket in ["user", "learned"] -> where(query, [m], m.bucket == ^bucket)
      _all -> query
    end
  end

  defp limit(opts) do
    case Keyword.get(opts, :limit) do
      value when is_integer(value) and value > 0 -> min(value, @maximum_listed)
      _absent -> @maximum_listed
    end
  end

  # A correction replaces one live row with another, so it is admitted at the
  # ceiling. Refusing it there would leave an account that has filled its store
  # unable to fix anything already in it.
  defp quota(_user, %Memory{}), do: {:ok, :superseding}

  defp quota(user, nil) do
    live =
      Repo.aggregate(
        from(memory in Memory,
          where: memory.user_id == ^user.id and is_nil(memory.superseded_by_id)
        ),
        :count
      )

    if live < maximum_live_memories(), do: {:ok, live}, else: {:error, :quota_reached}
  end

  defp superseded(user, attrs) do
    case Map.get(attrs, "supersedes") do
      nil ->
        {:ok, nil}

      id when is_binary(id) ->
        case fetch(user, id) do
          {:ok, %Memory{superseded_by_id: nil} = memory} -> {:ok, memory}
          _absent_or_already_superseded -> {:error, :supersedes_not_found}
        end

      _invalid ->
        {:error, :supersedes_not_found}
    end
  end

  defp link(_repo, %{supersedes: nil}), do: {:ok, nil}

  defp link(repo, %{supersedes: previous, memory: memory}) do
    previous
    |> Memory.supersede_changeset(memory)
    |> repo.update()
  end

  defp normalize(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  # `|| []` rather than a `get_env/3` default: the key can be present and nil,
  # and a nil there would reach `Keyword.get/3` as a hard crash rather than as
  # the configured fallback.
  defp setting(key, fallback) do
    (Application.get_env(:openagents, :memory_recall) || [])
    |> Keyword.get(key, fallback)
  end
end
