defmodule OpenAgents.Effects do
  @moduledoc """
  The durable effect outbox (EFFECT-001).

  An intent that asks for something outside its own transaction — launch a
  worker, call a provider, start a delegation — commits the asking with the
  intent. `enqueue/2` is called *inside* the caller's transaction; that is the
  whole point. Either the intent row and its effect row both exist or neither
  does, so there is no window in which the system has promised work it has no
  record of owing.

  After the commit the effect is anyone's to run. `claim_batch/2` takes a lease
  with a conditional update, so two workers racing for one effect produce one
  winner. `complete/1` and `fail/2` record the outcome. `reclaim_expired/1`
  returns to the queue whatever a dead worker was holding.

  ## The six milestones

  This module deliberately keeps apart the facts that a single sequence number
  would conflate (EFFECT-002):

    * **command admitted** — the caller's intent passed admission. Not here.
    * **event committed** — the intent row, and this effect row with it, are
      durable. `enqueue/2` returning inside a committed transaction.
    * **effect claimed** — a worker holds a lease and is about to try.
      `status = "claimed"`, `claimed_at`, `lease_owner`.
    * **effect completed** — the handler returned successfully.
      `status = "done"`, `completed_at`.
    * **turn quiesced** — the work the effect started has stopped. Owned by the
      thread and turn plane, not by this table.
    * **work verified** — someone accepted the result. Owned by receipts.

  A `thread_events` sequence is a transcript position, not an execution claim
  and not a completion claim. Nothing here reads one as either.
  """

  import Ecto.Query

  alias OpenAgents.Effects.Effect
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  @default_maximum_attempts 5
  @default_lease_seconds 120
  @default_batch_limit 20
  @default_backoff_base_ms 1_000
  @default_backoff_ceiling_ms 300_000
  @maximum_error_bytes 4_000

  @typedoc "Why an enqueue was refused."
  @type enqueue_error :: :payload_conflict | Ecto.Changeset.t()

  @doc """
  Record an effect the caller's transaction is committing.

  Call this inside the transaction that writes the intent. It performs one
  insert and participates in the ambient transaction, so a rollback takes the
  effect with it and nothing is delivered for work that never happened.

  ## Attributes

    * `:payload` — the handler's whole input, a map. Required.
    * `:source_kind` / `:source_id` — the committed intent that asked.
      Required.
    * `:source_sequence` — the intent's transcript position, where it has one.
      Recorded as evidence; never read as an execution or completion claim.
    * `:idempotency_key` — the effect's identity. Defaults to a deterministic
      key over the kind and source, so the same intent enqueued twice is one
      effect and one delivery.
    * `:maximum_attempts`, `:available_at` — delivery policy.

  Enqueuing the same key twice with the same payload returns the existing
  effect: an honest retry is not a second effect. Enqueuing the same key with a
  *different* payload returns `{:error, :payload_conflict}` rather than
  answering the second caller with the first caller's effect.
  """
  @spec enqueue(String.t(), map() | keyword()) :: {:ok, Effect.t()} | {:error, enqueue_error()}
  def enqueue(kind, attributes) when is_binary(kind) and is_list(attributes),
    do: enqueue(kind, Map.new(attributes))

  def enqueue(kind, attributes) when is_binary(kind) and is_map(attributes) do
    now = fetch(attributes, :now, DateTime.utc_now())
    payload = fetch(attributes, :payload, %{})
    source_kind = fetch(attributes, :source_kind, nil)
    source_id = attributes |> fetch(:source_id, nil) |> to_source_id()
    source_sequence = fetch(attributes, :source_sequence, nil)

    row = %{
      kind: kind,
      payload: payload,
      payload_digest: payload_digest(payload),
      source_kind: source_kind,
      source_id: source_id,
      source_sequence: source_sequence,
      idempotency_key:
        fetch(
          attributes,
          :idempotency_key,
          idempotency_key(kind, source_kind, source_id, source_sequence)
        ),
      maximum_attempts: fetch(attributes, :maximum_attempts, @default_maximum_attempts),
      available_at: fetch(attributes, :available_at, now)
    }

    changeset = Effect.enqueue_changeset(row)

    # `on_conflict` rather than a bare insert on purpose: a unique-violation
    # error would abort the caller's whole transaction, which would turn an
    # idempotent retry of the intent into a failure of the intent.
    insert =
      Repo.insert(changeset,
        on_conflict: {:replace, [:updated_at]},
        conflict_target: :idempotency_key,
        returning: true
      )

    case insert do
      {:ok, %Effect{payload_digest: digest} = effect} ->
        if digest == row.payload_digest, do: {:ok, effect}, else: {:error, :payload_conflict}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  The deterministic identity of an effect.

  Derived from the kind and the intent that asked for it, so the same intent
  produces the same key on every retry, on every node, after every restart.
  A handler receives it and may use it as its own idempotency token.
  """
  @spec idempotency_key(String.t(), String.t() | nil, String.t() | nil, integer() | nil) ::
          String.t()
  def idempotency_key(kind, source_kind, source_id, source_sequence \\ nil) do
    parts = [kind, source_kind || "", source_id || "", sequence_part(source_sequence)]
    "effect:" <> Canonical.sha256(Enum.join(parts, "|"))
  end

  @doc "The canonical fingerprint of an effect payload."
  @spec payload_digest(map()) :: String.t()
  def payload_digest(payload) when is_map(payload), do: "sha256:" <> Canonical.digest!(payload)

  @doc """
  Claim up to `:limit` deliverable effects for `worker`, taking a lease.

  Candidate ids are read first and then updated conditionally, so two workers
  racing over the same candidates each take a disjoint set: the loser's update
  matches zero rows because the status it required is no longer there. This is
  the same shape `OpenAgents.Deployments.claim_run/2` uses, for the same
  reason.

  Claiming is not completing. A claimed effect is one a worker said it would
  try, and nothing more (EFFECT-002).
  """
  @spec claim_batch(String.t(), keyword()) :: [Effect.t()]
  def claim_batch(worker, options \\ []) when is_binary(worker) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    limit = Keyword.get(options, :limit, @default_batch_limit)
    lease_seconds = Keyword.get(options, :lease_seconds, lease_seconds())
    expires_at = DateTime.add(now, lease_seconds, :second)
    kinds = Keyword.get(options, :kinds)

    candidates =
      Effect
      |> where([e], e.status == "pending" and e.available_at <= ^now)
      |> then(fn query ->
        if kinds, do: where(query, [e], e.kind in ^kinds), else: query
      end)
      |> order_by([e], asc: e.available_at, asc: e.inserted_at)
      |> limit(^limit)
      |> select([e], e.id)
      |> Repo.all()

    case candidates do
      [] ->
        []

      ids ->
        {_claimed, effects} =
          Repo.update_all(
            from(e in Effect,
              where: e.id in ^ids and e.status == "pending" and e.available_at <= ^now,
              select: e
            ),
            set: [
              status: "claimed",
              lease_owner: worker,
              lease_expires_at: expires_at,
              claimed_at: now,
              updated_at: now
            ],
            inc: [attempts: 1]
          )

        effects
    end
  end

  @doc """
  Record that an effect's handler succeeded.

  Idempotent under redelivery: completing an effect that is already `done`
  returns it unchanged rather than writing a second completion. A worker whose
  lease expired mid-flight, and whose effect another worker has since finished,
  therefore reports success without contradicting the record.
  """
  @spec complete(Effect.t() | String.t()) :: {:ok, Effect.t()} | {:error, :not_found}
  def complete(%Effect{id: id}), do: complete(id, nil)

  def complete(id) when is_binary(id), do: complete(id, nil)

  @doc """
  Record that an effect's handler succeeded, with an optional result payload.

  A handler that reached a terminal outcome without an external result can pass
  `nil`; a handler that produced an explicit result map can record it. The same
  idempotency rule applies: a completed effect returns its existing row.
  """
  @spec complete(Effect.t() | String.t(), map() | nil) :: {:ok, Effect.t()} | {:error, :not_found}
  def complete(%Effect{id: id}, result), do: complete(id, result)

  def complete(id, result) when is_binary(id) do
    now = DateTime.utc_now()

    {_count, updated} =
      Repo.update_all(
        from(e in Effect, where: e.id == ^id and e.status != "done", select: e),
        set: [
          status: "done",
          lease_owner: nil,
          lease_expires_at: nil,
          last_error: nil,
          result: result,
          completed_at: now,
          updated_at: now
        ]
      )

    case updated do
      [%Effect{} = effect] -> {:ok, effect}
      [] -> already_done(id)
    end
  end

  @doc """
  Record that an effect's handler failed.

  Below `maximum_attempts` the effect returns to `pending` with `available_at`
  pushed out by exponential backoff, and the lease is released so any worker
  may take the next attempt. At the ceiling it becomes terminally `failed` and
  stops being delivered — an effect that cannot be run must stop pretending it
  will be, so that something else can notice.
  """
  @spec fail(Effect.t() | String.t(), term()) :: {:ok, Effect.t()} | {:error, :not_found}
  def fail(%Effect{id: id}, reason), do: fail(id, reason)

  def fail(id, reason) when is_binary(id) do
    now = DateTime.utc_now()
    message = error_message(reason)

    case Repo.get(Effect, id) do
      nil ->
        {:error, :not_found}

      %Effect{status: "done"} = effect ->
        {:ok, effect}

      %Effect{attempts: attempts, maximum_attempts: maximum} = effect
      when attempts >= maximum ->
        set_fields(effect, %{
          status: "failed",
          lease_owner: nil,
          lease_expires_at: nil,
          last_error: message,
          completed_at: now,
          updated_at: now
        })

      %Effect{attempts: attempts} = effect ->
        set_fields(effect, %{
          status: "pending",
          lease_owner: nil,
          lease_expires_at: nil,
          last_error: message,
          available_at: DateTime.add(now, backoff_ms(attempts), :millisecond),
          updated_at: now
        })
    end
  end

  @doc """
  Return to the queue every effect whose lease has run out.

  A worker that died holding a lease loses nothing: the effect it claimed
  becomes deliverable again, on this node or any other. The attempt it already
  spent is not refunded, so a handler that reliably kills its worker still
  reaches `maximum_attempts` and stops.

  Returns the number of effects reclaimed.
  """
  @spec reclaim_expired(keyword()) :: non_neg_integer()
  def reclaim_expired(options \\ []) do
    now = Keyword.get(options, :now, DateTime.utc_now())

    {count, _rows} =
      Repo.update_all(
        from(e in Effect,
          where: e.status == "claimed" and e.lease_expires_at <= ^now
        ),
        set: [
          status: "pending",
          lease_owner: nil,
          lease_expires_at: nil,
          available_at: now,
          updated_at: now
        ]
      )

    count
  end

  @doc "Fetch one effect by id."
  @spec get(String.t()) :: Effect.t() | nil
  def get(id) when is_binary(id), do: Repo.get(Effect, id)

  @doc "Fetch the effect an intent enqueued, by its deterministic key."
  @spec get_by_key(String.t()) :: Effect.t() | nil
  def get_by_key(key) when is_binary(key), do: Repo.get_by(Effect, idempotency_key: key)

  @doc "Every effect a given intent asked for, oldest first."
  @spec for_source(String.t(), String.t()) :: [Effect.t()]
  def for_source(source_kind, source_id) when is_binary(source_kind) do
    Repo.all(
      from e in Effect,
        where: e.source_kind == ^source_kind and e.source_id == ^to_source_id(source_id),
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  @doc "How many effects hold each status, for operators and tests."
  @spec counts() :: %{String.t() => non_neg_integer()}
  def counts do
    Effect
    |> group_by([e], e.status)
    |> select([e], {e.status, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  A bounded token naming why an effect failed, safe to log.

  The durable `last_error` column holds the detail, redacted; a log line holds
  only this. A reason's shape decides the token: an atom is itself, a tagged
  tuple is its tag, anything else is `unknown`. Nothing derived from a payload
  reaches a log through here.
  """
  @spec error_code(term()) :: String.t()
  def error_code(reason) when is_atom(reason), do: bounded_code(reason)
  def error_code(tag) when is_tuple(tag) and tuple_size(tag) > 0, do: error_code(elem(tag, 0))
  def error_code(_reason), do: "unknown"

  @doc "The lease length a claim takes by default."
  @spec lease_seconds() :: pos_integer()
  def lease_seconds, do: setting(:lease_seconds, @default_lease_seconds)

  @doc "How long an effect waits before its `attempts`-th retry."
  @spec backoff_ms(non_neg_integer()) :: non_neg_integer()
  def backoff_ms(attempts) when is_integer(attempts) and attempts >= 0 do
    base = setting(:backoff_base_ms, @default_backoff_base_ms)
    ceiling = setting(:backoff_ceiling_ms, @default_backoff_ceiling_ms)
    exponent = max(attempts - 1, 0) |> min(16)
    min(base * Integer.pow(2, exponent), ceiling)
  end

  defp already_done(id) do
    case Repo.get(Effect, id) do
      %Effect{} = effect -> {:ok, effect}
      nil -> {:error, :not_found}
    end
  end

  defp set_fields(%Effect{} = effect, changes) do
    {_count, [updated]} =
      Repo.update_all(
        from(e in Effect, where: e.id == ^effect.id, select: e),
        set: Map.to_list(changes)
      )

    {:ok, updated}
  end

  defp fetch(attributes, key, default) do
    case Map.fetch(attributes, key) do
      {:ok, nil} -> default
      {:ok, value} -> value
      :error -> Map.get(attributes, to_string(key), default)
    end
  end

  defp to_source_id(nil), do: nil
  defp to_source_id(value) when is_binary(value), do: value
  defp to_source_id(value) when is_integer(value), do: Integer.to_string(value)

  defp sequence_part(nil), do: ""
  defp sequence_part(sequence) when is_integer(sequence), do: Integer.to_string(sequence)

  # A handler's failure reason can carry whatever the far side said, including
  # a URL with a credential in it. It is bounded and redacted before it becomes
  # a durable column, once, here — not at each of the places that read it.
  defp error_message(reason) when is_binary(reason),
    do: reason |> OpenAgents.LogSafety.redact() |> String.slice(0, @maximum_error_bytes)

  defp error_message(reason),
    do:
      reason
      |> inspect(limit: 50, printable_limit: 2_000)
      |> OpenAgents.LogSafety.redact()
      |> String.slice(0, @maximum_error_bytes)

  defp bounded_code(atom) do
    atom
    |> Atom.to_string()
    |> String.replace(~r/[^A-Za-z0-9_.]/, "_")
    |> String.slice(0, 64)
  end

  defp setting(key, default) do
    :openagents
    |> Application.get_env(:effects, [])
    |> Keyword.get(key, default)
  end
end
