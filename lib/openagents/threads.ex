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

  ## What is not here

  There is no cap on concurrent open threads or on concurrent active grants per
  account. That ceiling belongs at admission in `open/3`, reading a limit from
  `config/config.exs` next to the Box lane's `maximum_active_boxes_per_owner`,
  and it is stage 2's work: the cap is an abuse control on the public route
  that mints authority, and no such route exists yet.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OpenAgents.Accounts.User
  alias OpenAgents.Chat.OpenRouter
  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.Inference
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Repo
  alias OpenAgents.Threads.Event
  alias OpenAgents.Threads.Thread

  @maximum_listed 50

  @doc """
  Open a thread for an account.

  The owner visitor is resolved (and created if absent) without touching the
  account's conversation. The admitted execution shape defaults to the chat
  lane's configured model, `high` reasoning, and the `read_only` permission
  profile; a caller may narrow or widen only within the admitted vocabulary.
  """
  @spec open(User.t() | Visitor.t(), String.t(), keyword()) ::
          {:ok, Thread.t()} | {:error, Ecto.Changeset.t()}
  def open(owner, objective, options \\ [])

  def open(%User{} = user, objective, options) do
    user |> Conversations.ensure_owner_visitor() |> open(objective, options)
  end

  def open(%Visitor{id: visitor_id}, objective, options) when is_binary(objective) do
    now = DateTime.utc_now()

    attributes = %{
      objective: objective,
      model: Keyword.get(options, :model) || OpenRouter.default_model(),
      reasoning_effort: OpenRouter.reasoning_effort(Keyword.get(options, :reasoning, "high")),
      permission_profile: Keyword.get(options, :permission_profile, "read_only")
    }

    Multi.new()
    |> Multi.insert(:thread, Thread.open_changeset(attributes, visitor_id, now))
    |> Multi.run(:opened_event, fn _repo, %{thread: thread} ->
      insert_event(thread, "thread.opened", %{"objective_bytes" => byte_size(objective)}, now)
    end)
    |> Multi.update(:counted, fn %{thread: thread} ->
      Thread.event_count_changeset(thread, thread.event_count + 1)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{counted: thread}} -> {:ok, thread}
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

  @doc "The account's threads, newest first, bounded."
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
    |> Repo.all()
  end

  @doc "The thread's transcript, oldest first, bounded."
  @spec list_events(Thread.t(), keyword()) :: [Event.t()]
  def list_events(%Thread{id: thread_id}, options \\ []) do
    limit = options |> Keyword.get(:limit, @maximum_listed) |> min(@maximum_listed) |> max(1)

    from(e in Event,
      where: e.thread_id == ^thread_id,
      order_by: [asc: e.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Append one bounded event to a thread's transcript and advance its counter.

  Refused on a terminal thread: a transcript that keeps growing after the
  report was written is not the transcript the report describes.
  """
  @spec record_event(Thread.t(), String.t(), map()) ::
          {:ok, Thread.t()} | {:error, :thread_terminal | Ecto.Changeset.t()}
  def record_event(%Thread{} = thread, event_type, payload)
      when is_binary(event_type) and is_map(payload) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      case locked(thread.id) do
        %Thread{status: "open"} = current ->
          with {:ok, _event} <- insert_event(current, event_type, payload, now),
               {:ok, updated} <-
                 current |> Thread.event_count_changeset(current.event_count + 1) |> Repo.update() do
            updated
          else
            {:error, reason} -> Repo.rollback(reason)
          end

        _terminal ->
          Repo.rollback(:thread_terminal)
      end
    end)
  end

  @doc """
  Mint model authority for a thread.

  This is the fence. In one transaction: the thread is locked and refused
  unless it is open, every active grant naming it is revoked, `generation` is
  bumped, and a fresh grant is minted against the thread — never against a
  conversation. Returns the plaintext token exactly once.
  """
  @spec mint_grant(Thread.t()) ::
          {:ok, Thread.t(), Grant.t(), String.t()}
          | {:error, :thread_terminal | Ecto.Changeset.t()}
  def mint_grant(%Thread{} = thread) do
    Repo.transaction(fn ->
      case locked(thread.id) do
        %Thread{status: "open"} = current ->
          _revoked = Inference.revoke_active_for_thread(current.id)

          with {:ok, fenced} <- current |> Thread.generation_changeset() |> Repo.update(),
               {:ok, grant, token} <-
                 Inference.mint(%{
                   owner_visitor_id: fenced.owner_visitor_id,
                   thread_id: fenced.id,
                   machine_id: nil
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

  defp locked(thread_id) do
    Repo.one(from t in Thread, where: t.id == ^thread_id, lock: "FOR UPDATE")
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
