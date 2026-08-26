defmodule OpenAgentsWeb.ThreadController do
  @moduledoc """
  The door to a thread: open one, read what it has spent, say what it did,
  revoke it.

  A thread is the unit of agent work (`docs/taxonomy.md`), and its grant is the
  only way a client reaches a model without holding a provider key. So these
  three routes hand out authority, and the controls that authority needs live
  here rather than being assumed:

  - **Admission is capped.** `OpenAgents.Threads.open/3` refuses an account
    already holding `maximum_open_threads_per_account` open threads, and the
    refusal names the limit. Without it, a token that opens one thread opens
    unbounded threads.
  - **The budget is the thread's own.** A grant minted here carries
    `OpenAgents.Threads.ceilings/0`, never the delegation ceilings a probe run
    is minted with.
  - **Revocation does not wait to be asked.** `DELETE` revokes immediately, and
    every request first retires the account's elapsed authority, so a grant
    past its expiry stops being live whether or not anyone presents it.
  - **Ending honestly is a different act from being cancelled.**
    `POST /report` writes what the thread did and revokes; `DELETE` writes a
    cancellation and revokes. A session that answered and exited 0 has to be
    able to say so, or its permanent record says the opposite of what happened
    (issue #106) — and a session that failed has to be unable to claim it
    succeeded, which is the same bug pointed the other way.
  - **Disclosure is opt-in and narrow.** A thread opens `dark` — owner-only —
    unless the caller names a wider transparency tier, and a tier this surface
    cannot enforce is refused with `thread_visibility_unsupported`. A wider
    tier reaches `show/2` and `events/2` and nothing else: the writes and the
    mint stay owner-only, and a reader admitted by the tier is not shown the
    owner's grant (THREAD-002).

  The model is admitted here and nowhere else. A request body sent to the proxy
  still cannot select a model — the proxy pins the grant's — so the one place a
  caller states which model it wants is the thread it opens, and the response
  publishes the model the grant carries. Admitting it at the door is what lets
  a coding session run its own turns on one model and its delegated children on
  another: it opens a second thread on `gemini-3.7-flash` and gets authority
  for `gemini-3.7-flash`, with its own budget, rather than borrowing the first
  thread's.

  The exception is the `local` lane, and it is an exception to the grant, not
  to the record. `"lane": "local"` opens a transcript-only thread: the model is
  the bounded vendor string a local runtime serves (`ollama:...`), checked
  against no catalog and no provider, and the open mints nothing — the response
  carries no grant, and `POST /grants` on the thread is refused with
  `thread_lane_local`. Everything else is an ordinary thread: events append,
  the transcript streams, the tier governs its readers, the open-thread cap
  counts it, `DELETE` ends it. The lane exists so a run whose model calls never
  touch this server still leaves the durable transcript everything rehydrates
  from (issue #243).
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Conversations
  alias OpenAgents.Inference
  alias OpenAgents.Inference.{Credit, Grant, Models, Pricing}
  alias OpenAgents.Threads
  alias OpenAgents.Threads.Thread
  alias OpenAgentsWeb.ApiError

  @extension "thread.openagents"

  def create(conn, params) do
    with {:ok, lane} <- lane(params),
         {:ok, objective} <- objective(params),
         {:ok, repository} <- repository(params),
         {:ok, visibility} <- visibility(params),
         {:ok, options} <- shape_for(lane, params) do
      case lane do
        "local" -> open_local(conn, objective, options ++ repository ++ visibility)
        _granted -> open(conn, objective, options ++ repository ++ visibility)
      end
    else
      {:refused, field, message} -> ApiError.validation_failed(conn, %{field => [message]})
      {:unavailable, model_id} -> unavailable_model(conn, model_id)
      {:unsupported_visibility, value} -> unsupported_visibility(conn, value)
    end
  end

  @doc """
  The account's threads, newest first.

  A client that outlives its process needs a way back to the work it was doing,
  and the account is the only place that knows. Bounded by the context, which
  caps what a list may return.
  """
  def index(conn, params) do
    user = conn.assigns.current_user
    _reaped = Threads.reap_expired(user)

    threads =
      Threads.list_for_user(user, params |> listing_options() |> repository_filter(params))

    conn
    |> put_extension_header()
    |> json(%{"threads" => Enum.map(threads, &thread_view/1)})
  end

  @doc """
  A thread's transcript, oldest first.

  This is where a session's history lives. It is the server's copy and the only
  copy: a client reads it back rather than keeping its own, so two machines
  reading one thread see one transcript rather than two that have diverged.
  """
  def events(conn, %{"thread_id" => thread_id} = params) do
    with_readable_thread(conn, thread_id, fn thread, _relation ->
      events = Threads.list_events(thread, listing_options(params))

      conn
      |> put_extension_header()
      |> json(%{
        "thread_id" => thread.id,
        "event_count" => thread.event_count,
        "events" => Enum.map(events, &event_view/1)
      })
    end)
  end

  @doc """
  Append to a thread's transcript: one event, or a batch of them.

  Append-only and bounded: the payload is capped by the database, and a
  terminal thread refuses, because a transcript that keeps growing after the
  report was written is not the transcript the report describes.

  One route serves both shapes — `{"event_type": ..., "payload": ...}` appends
  one event, `{"events": [...]}` appends a batch — because there is one door to
  a transcript and the batch is the same act performed fewer round trips at a
  time. A batch lands all-or-nothing in one transaction, in order, capped at
  `OpenAgents.Threads.maximum_event_batch/0`, and the created events come back
  in order so a client learns every id it just wrote.

  A refused event carries the stable code `event_invalid` beside the field
  errors, symmetric with `thread_terminal`, so a client tells a drop-only
  refusal from a retry-safe one without parsing prose.
  """
  def record(conn, %{"thread_id" => thread_id} = params) do
    with_thread(conn, thread_id, fn thread ->
      case Map.fetch(params, "events") do
        {:ok, events} -> record_batch(conn, thread, events)
        :error -> record_single(conn, thread, params)
      end
    end)
  end

  defp record_single(conn, thread, params) do
    case event_parameters(params) do
      {:ok, event_type, payload} -> append(conn, thread, event_type, payload)
      {:refused, field, message} -> event_invalid(conn, %{field => [message]})
    end
  end

  defp record_batch(conn, thread, events) do
    case batch_parameters(events) do
      {:ok, entries} -> append_batch(conn, thread, entries)
      {:refused, field, message} -> event_invalid(conn, %{field => [message]})
      {:oversized, count, cap} -> batch_too_large(conn, count, cap)
    end
  end

  @doc """
  One thread, with the grant it holds.

  This and `events/2` are the two reads a wider transparency tier reaches. The
  grant is not part of what a tier discloses: it is the owner's money, so a
  reader admitted by the thread's tier gets `"grant": null` rather than the
  account's ceilings and spend (THREAD-002).
  """
  def show(conn, %{"thread_id" => thread_id}) do
    with_readable_thread(conn, thread_id, fn thread, relation ->
      render_thread(conn, :ok, thread, relation)
    end)
  end

  @doc """
  Say what the thread did, and end it.

  This is the route a session calls when its work is over and it has something
  to say about it. Without it the only way to end a thread was `DELETE`, which
  writes `cancelled` and the sentence "The thread was cancelled before it
  reported." — so a session that answered correctly and exited 0 was recorded
  as a cancellation, and 31 of one account's 50 most recent threads read that
  way (issue #106). The record said the opposite of what happened.

  The outcome is the caller's to state, and stating it is mandatory. A body
  with no `status` is refused rather than filed as a success: the server did
  not run the turns and has no way to know whether they answered anything, and
  a default of `succeeded` would be the same bug pointed the other way — a run
  that failed, was interrupted, or exhausted its steps recorded as having
  worked. The status and the error code have to agree: `succeeded` carries no
  error code, and `failed` or `cancelled` has to name one. Both halves are
  refused by `OpenAgents.Threads.Thread.terminal_changeset/2` and by
  `threads_terminal_outcome_check`, so no client and no future caller can file
  a pair that disagrees.

  Ending revokes, exactly as `DELETE` does — authority does not outlive the
  thread (THREAD-001) — and the response carries the revoked grant so a client
  reads what the session spent in the same answer that ends it.

  A resent identical report is answered rather than refused, so a client that
  retries a timed-out call is not told its own report failed. A *different*
  second report is refused `thread_terminal`: a thread reports once, and the
  standing report is not overwritten by a later claim.

  A thread that reported is not finished with. `POST /grants` reopens it and
  hands back fresh authority, which is what `oa coder --resume` needs; see
  `mint/2`.
  """
  def report(conn, %{"thread_id" => thread_id} = params) do
    with_thread(conn, thread_id, fn thread ->
      case outcome(params) do
        {:ok, result} -> file_report(conn, thread, result)
        {:refused, field, message} -> ApiError.validation_failed(conn, %{field => [message]})
      end
    end)
  end

  defp file_report(conn, thread, result) do
    case Threads.finish(thread, result) do
      {:ok, finished} ->
        render_thread(conn, :ok, finished)

      {:error, :thread_terminal} ->
        replay_or_refuse(conn, thread, result)

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  end

  # A client that retried a call it never saw the answer to is not reporting
  # twice; it is asking whether its one report landed. So an identical resend
  # is answered with the standing thread, and only a report that says something
  # different is refused.
  defp replay_or_refuse(conn, thread, result) do
    if thread.report == Map.fetch!(result, :report) and
         thread.status == Map.fetch!(result, :status) do
      render_thread(conn, :ok, thread)
    else
      sentence =
        "This thread is #{thread.status} and has already reported. " <>
          "A thread reports once; open another thread instead."

      ApiError.refuse(conn, "thread_terminal",
        message: sentence,
        errors: %{"thread" => [sentence]}
      )
    end
  end

  def delete(conn, %{"thread_id" => thread_id}) do
    with_thread(conn, thread_id, fn thread ->
      # Cancelling revokes the thread's authority inside the transaction that
      # writes the terminal row (THREAD-001). A thread that is already terminal
      # already holds no authority, so a second call is answered, not refused.
      case Threads.cancel(thread) do
        {:ok, cancelled} -> render_thread(conn, :ok, cancelled)
        {:error, :thread_terminal} -> render_thread(conn, :ok, thread)
        {:error, changeset} -> ApiError.changeset(conn, changeset)
      end
    end)
  end

  @doc """
  Re-mint a thread's authority: the resume door.

  Re-minting is the resume fence — it revokes every active grant, bumps the
  generation, and hands back fresh authority on the same thread, so a resumed
  session can never race a zombie of its former self (THREAD-001). The
  plaintext token exists exactly once, in this response, like the one
  `POST /api/v1/threads` returns.

  A thread that reported is reopened here rather than refused. Every honest end
  is terminal, so refusing every terminal thread meant a client could keep a
  thread resumable only by never saying what it did — the transcript would be
  there and no session could be granted authority to continue it. What it
  reported is written into the transcript as `thread.reopened` before the
  terminal columns clear, so reopening loses nothing.

  A cancelled thread is refused `thread_terminal`. `DELETE` is a disposal, and
  a caller that used it asked for the thread to be over; resuming it would make
  cancellation mean nothing. A local-lane thread is refused `thread_lane_local`
  in every state: it can never hold authority at all.
  """
  def mint(conn, %{"thread_id" => thread_id}) do
    with_thread(conn, thread_id, fn thread ->
      case Threads.mint_grant(thread) do
        {:ok, minted, grant, token} ->
          conn
          |> put_extension_header()
          |> put_status(:created)
          |> json(%{"thread" => thread_view(minted), "grant" => minted_view(grant, token)})

        {:error, :thread_terminal} ->
          sentence =
            "This thread was cancelled, so it holds no authority to re-mint and " <>
              "cannot be resumed. Open another thread instead. A thread that " <>
              "reported its outcome can be resumed here; a cancelled one is over."

          ApiError.refuse(conn, "thread_terminal",
            message: sentence,
            errors: %{"thread" => [sentence]}
          )

        {:error, :thread_local_lane} ->
          sentence =
            "This thread is on the local lane and holds no model authority to mint: " <>
              "its model runs on the caller's own machine, and this server only " <>
              "records the transcript. Open a thread without \"lane\": \"local\" " <>
              "for a grant."

          ApiError.refuse(conn, "thread_lane_local",
            message: sentence,
            errors: %{"thread" => [sentence]}
          )

        {:error, :thread_quota_reached} ->
          quota_reached(conn)

        {:error, :credit_exhausted} ->
          credit_exhausted(conn)

        {:error, %Ecto.Changeset{} = changeset} ->
          ApiError.changeset(conn, changeset)

        {:error, _reason} ->
          ApiError.validation_failed(conn, %{
            "thread" => ["The grant could not be minted. Try again."]
          })
      end
    end)
  end

  # The created event is the point of the 201: its id is the cursor a client
  # continues from, and a writer that never learns it cannot dedup its own
  # append against a later read. The thread rides along for the count.
  defp append(conn, thread, event_type, payload) do
    case Threads.record_events(thread, [%{event_type: event_type, payload: payload}]) do
      {:ok, updated, [event]} ->
        conn
        |> put_extension_header()
        |> put_status(:created)
        |> json(%{"event" => event_view(event), "thread" => thread_view(updated)})

      {:error, :thread_terminal} ->
        thread_terminal(conn, thread)

      {:error, {_index, changeset}} ->
        event_invalid(conn, ApiError.changeset_errors(changeset))

      {:error, %Ecto.Changeset{} = changeset} ->
        event_invalid(conn, ApiError.changeset_errors(changeset))
    end
  end

  defp append_batch(conn, thread, entries) do
    case Threads.record_events(thread, entries) do
      {:ok, updated, events} ->
        conn
        |> put_extension_header()
        |> put_status(:created)
        |> json(%{"events" => Enum.map(events, &event_view/1), "thread" => thread_view(updated)})

      {:error, :thread_terminal} ->
        thread_terminal(conn, thread)

      {:error, {index, changeset}} ->
        errors =
          changeset
          |> ApiError.changeset_errors()
          |> Map.new(fn {field, messages} -> {"events[#{index}].#{field}", messages} end)

        event_invalid(conn, errors)

      {:error, %Ecto.Changeset{} = changeset} ->
        event_invalid(conn, ApiError.changeset_errors(changeset))
    end
  end

  defp thread_terminal(conn, thread) do
    sentence =
      "This thread is #{thread.status} and its transcript is closed. " <>
        "Open another thread to record more work."

    ApiError.refuse(conn, "thread_terminal",
      message: sentence,
      errors: %{"thread" => [sentence]}
    )
  end

  defp event_invalid(conn, errors) do
    ApiError.refuse(conn, "event_invalid", errors: errors)
  end

  defp batch_too_large(conn, count, cap) do
    sentence =
      "This batch carries #{count} events and the maximum is #{cap}. " <>
        "Split it and post the parts in order."

    ApiError.refuse(conn, "event_batch_too_large",
      message: sentence,
      errors: %{"events" => [sentence]}
    )
  end

  # ── admission ───────────────────────────────────────────────────────────

  defp open(conn, objective, options) do
    case Threads.open_and_mint(conn.assigns.current_user, objective, options) do
      {:ok, thread, grant, token} ->
        conn
        |> put_extension_header()
        |> put_status(:created)
        |> json(%{"thread" => thread_view(thread), "grant" => minted_view(grant, token)})

      {:error, :thread_quota_reached} ->
        quota_reached(conn)

      {:error, :credit_exhausted} ->
        credit_exhausted(conn)

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)

      {:error, _reason} ->
        ApiError.validation_failed(conn, %{
          "objective" => ["The thread could not be opened. Try again."]
        })
    end
  end

  # The transcript-only open. No mint, so no token, no grant key, and no
  # `credit_exhausted` — an account with nothing left can still record a run
  # its own machine paid for. The quota refusal is the same one the granted
  # lane gets, because the cap counts open threads, not granted ones.
  defp open_local(conn, objective, options) do
    case Threads.open(conn.assigns.current_user, objective, options) do
      {:ok, thread} ->
        conn
        |> put_extension_header()
        |> put_status(:created)
        |> json(%{"thread" => thread_view(thread)})

      {:error, :thread_quota_reached} ->
        quota_reached(conn)

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  end

  # The refusal names the ceiling and the account's own count, so a client that
  # scripts several checkouts learns what to close rather than what to retry.
  defp quota_reached(conn) do
    limit = Threads.maximum_open_per_account()
    held = Threads.open_count(conn.assigns.current_user)

    sentence =
      "This account holds #{held} open threads and the configured maximum is #{limit}. " <>
        "Revoke a thread with DELETE /api/v1/threads/{thread_id} before opening another."

    ApiError.refuse(conn, "thread_quota_reached",
      message: sentence,
      errors: %{"threads" => [sentence]}
    )
  end

  # A thread spends the account's credit, so an exhausted balance is not a
  # thing to retry. The refusal names the allowance that was spent, because
  # that is the fact a reader acts on.
  defp credit_exhausted(conn) do
    visitor = Conversations.ensure_owner_visitor(conn.assigns.current_user)

    sentence =
      "This account has spent its inference credit of " <>
        "#{dollars(Credit.allowance(visitor.id))}. " <>
        "Nothing is left to mint a thread against."

    ApiError.refuse(conn, "credit_exhausted",
      message: sentence,
      errors: %{"credit" => [sentence]}
    )
  end

  defp dollars(microusd), do: "$#{:erlang.float_to_binary(microusd / 1_000_000, decimals: 2)}"

  # ── reading ─────────────────────────────────────────────────────────────

  # Expiry is retired before the lookup, so a read reports what is true now
  # rather than what was true when the grant was minted.
  #
  # Owner-only, and deliberately so: this is what every write and every
  # authority-bearing route resolves through. A thread published for reading is
  # not a thread a stranger may append to, cancel, or re-mint.
  defp with_thread(conn, thread_id, continue) do
    user = conn.assigns.current_user
    _reaped = Threads.reap_expired(user)

    case Threads.get_for_user(user, thread_id) do
      %Thread{} = thread -> continue.(thread)
      nil -> ApiError.not_found(conn)
    end
  end

  # The read half. A thread the account owns, or somebody else's thread at a
  # tier that admits this reader; anything else is the same plain 404 a
  # non-owner has always received, so a `dark` thread's existence is still not
  # confirmed to a stranger.
  defp with_readable_thread(conn, thread_id, continue) do
    user = conn.assigns.current_user
    _reaped = Threads.reap_expired(user)

    case Threads.fetch_readable(user, thread_id) do
      {:ok, thread, relation} -> continue.(thread, relation)
      :error -> ApiError.not_found(conn)
    end
  end

  defp render_thread(conn, status, %Thread{} = thread, relation \\ :owner) do
    conn
    |> put_extension_header()
    |> put_status(status)
    |> json(%{
      "thread" => thread_view(thread),
      "grant" => grant_view(thread, relation)
    })
  end

  # ── parameters ──────────────────────────────────────────────────────────

  # A limit outside the bounds is clamped by the context rather than refused: a
  # listing is a read, and a caller asking for more than the cap gets the cap.
  defp listing_options(params) do
    case Map.get(params, "limit") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {limit, ""} -> [limit: limit]
          _unparsed -> []
        end

      _absent ->
        []
    end
    |> continue_from(params)
  end

  defp continue_from(options, params) do
    case Map.get(params, "after") do
      value when is_binary(value) -> Keyword.put(options, :after, value)
      _absent -> options
    end
  end

  # An exact match on the recorded string, so `?repository=` narrows the
  # listing to the threads opened against that repository. A blank filter is
  # no filter: nothing records a blank repository, and an empty listing would
  # read as an account with no threads.
  defp repository_filter(options, params) do
    case Map.get(params, "repository") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> options
          repository -> Keyword.put(options, :repository, repository)
        end

      _absent ->
        options
    end
  end

  defp event_parameters(params) do
    with {:ok, event_type} <- event_type(params),
         {:ok, payload} <- payload(params) do
      {:ok, event_type, payload}
    end
  end

  # The whole batch is parsed before anything is appended, so a refusal names
  # the entry by its position and leaves nothing behind. An empty batch is
  # refused rather than answered 201: a client that posted nothing and read
  # "created" would believe something landed.
  defp batch_parameters(events) when is_list(events) do
    cap = Threads.maximum_event_batch()

    cond do
      events == [] ->
        {:refused, "events", "A batch appends at least one event."}

      length(events) > cap ->
        {:oversized, length(events), cap}

      true ->
        events
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {event, index}, {:ok, entries} ->
          case batch_entry(event, index) do
            {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
            {:refused, _field, _message} = refusal -> {:halt, refusal}
          end
        end)
        |> case do
          {:ok, entries} -> {:ok, Enum.reverse(entries)}
          {:refused, _field, _message} = refusal -> refusal
        end
    end
  end

  defp batch_parameters(_events) do
    {:refused, "events", "The events key carries an array of events."}
  end

  defp batch_entry(event, index) when is_map(event) do
    case event_parameters(event) do
      {:ok, event_type, payload} ->
        {:ok, %{event_type: event_type, payload: payload}}

      {:refused, field, message} ->
        {:refused, "events[#{index}].#{field}", message}
    end
  end

  defp batch_entry(event, index) do
    {:refused, "events[#{index}]", "#{inspect(event)} is not an object."}
  end

  # What a thread reports, read from the body with nothing inferred. Every
  # refusal here is a 422 naming its field: the alternative is guessing, and a
  # guess that lands on `succeeded` is the mirror of the bug this route exists
  # to fix (issue #106).
  defp outcome(params) do
    with {:ok, status} <- terminal_status(params),
         {:ok, report} <- terminal_report(params),
         {:ok, error_code} <- error_code(params, status),
         {:ok, report_type} <- report_type(params),
         {:ok, usage} <- usage(params) do
      {:ok,
       %{
         status: status,
         report: report,
         error_code: error_code,
         usage: usage
       }
       |> put_present(:report_type, report_type)}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp terminal_status(%{"status" => status}) when is_binary(status) do
    if status in Thread.terminal_statuses() do
      {:ok, status}
    else
      {:refused, "status",
       "must be one of #{Enum.join(Thread.terminal_statuses(), ", ")}, naming how the thread ended"}
    end
  end

  defp terminal_status(_params) do
    {:refused, "status",
     "is required: name how the thread ended, one of " <>
       "#{Enum.join(Thread.terminal_statuses(), ", ")}. The server does not assume a run " <>
       "succeeded because it stopped."}
  end

  defp terminal_report(%{"report" => report}) when is_binary(report) do
    case String.trim(report) do
      "" -> {:refused, "report", "cannot be blank"}
      _present -> {:ok, report}
    end
  end

  defp terminal_report(_params), do: {:refused, "report", "is required"}

  # A success that names an error code and a failure that names none are both
  # refused, because the durable record has to say one thing about what
  # happened rather than two.
  defp error_code(params, status) do
    given = params |> Map.get("error_code") |> blank_to_nil()

    cond do
      not is_nil(Map.get(params, "error_code")) and not is_binary(Map.get(params, "error_code")) ->
        {:refused, "error_code", "must be a string"}

      status == Thread.succeeded() and given != nil ->
        {:refused, "error_code",
         "must be empty on a thread that succeeded; report the status the run actually had"}

      status != Thread.succeeded() and given == nil ->
        {:refused, "error_code", "is required on a thread that did not succeed: name why"}

      true ->
        {:ok, given}
    end
  end

  defp report_type(%{"report_type" => report_type}) when is_binary(report_type) do
    case String.trim(report_type) do
      "" -> {:refused, "report_type", "cannot be blank"}
      trimmed when byte_size(trimmed) > 80 -> {:refused, "report_type", "is longer than 80 bytes"}
      _present -> {:ok, report_type}
    end
  end

  defp report_type(%{"report_type" => value}) when not is_nil(value) do
    {:refused, "report_type", "must be a string"}
  end

  defp report_type(_params), do: {:ok, nil}

  defp usage(%{"usage" => usage}) when is_map(usage), do: {:ok, usage}
  defp usage(%{"usage" => nil}), do: {:ok, %{}}
  defp usage(%{"usage" => _other}), do: {:refused, "usage", "must be an object"}
  defp usage(_params), do: {:ok, %{}}

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _present -> value
    end
  end

  defp blank_to_nil(_value), do: nil

  defp event_type(%{"event_type" => event_type}) when is_binary(event_type) do
    if String.trim(event_type) == "" do
      {:refused, "event_type", "The event type names what happened and cannot be blank."}
    else
      {:ok, event_type}
    end
  end

  defp event_type(_params) do
    {:refused, "event_type", "An event requires an event_type: what happened."}
  end

  defp payload(%{"payload" => payload}) when is_map(payload), do: {:ok, payload}

  defp payload(%{"payload" => payload}) do
    {:refused, "payload", "#{inspect(payload)} is not an object."}
  end

  defp payload(_params), do: {:ok, %{}}

  defp objective(%{"objective" => objective}) when is_binary(objective) do
    if String.trim(objective) == "" do
      {:refused, "objective", "The objective states what the thread is for and cannot be blank."}
    else
      {:ok, objective}
    end
  end

  defp objective(_params) do
    {:refused, "objective", "A thread requires an objective: what this body of work is for."}
  end

  # Optional, trimmed, non-blank when present. No format rule and no lookup
  # against the forge's repository table: a thread may concern a repository the
  # forge does not host, so the field records the opener's `owner/name` string
  # as given. The bound is the changeset's (issue #210).
  defp repository(%{"repository" => repository}) when is_binary(repository) do
    case String.trim(repository) do
      "" ->
        {:refused, "repository",
         "The repository names where the work runs and cannot be blank. Omit it instead."}

      trimmed ->
        {:ok, [repository: trimmed]}
    end
  end

  defp repository(%{"repository" => repository}) do
    {:refused, "repository", "#{inspect(repository)} is not a string."}
  end

  defp repository(_params), do: {:ok, []}

  # The consent gate. Absent means owner-only, because the tier a caller did
  # not ask for is the narrow one. A value outside the admitted set — a tier
  # this surface cannot enforce, or a word that is not a tier at all — is
  # refused with its own code rather than folded into the generic 422: a client
  # widening a transcript is making a disclosure decision, and it should learn
  # that the decision did not take, not guess from a field message.
  defp visibility(%{"visibility" => value}) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed in Thread.visibilities() do
      {:ok, [visibility: trimmed]}
    else
      {:unsupported_visibility, trimmed}
    end
  end

  defp visibility(%{"visibility" => value}) when not is_nil(value) do
    {:refused, "visibility", "#{inspect(value)} is not a string."}
  end

  defp visibility(_params), do: {:ok, []}

  defp unsupported_visibility(conn, value) do
    sentence =
      "#{inspect(value)} is not an admitted thread visibility. " <>
        "Admitted: #{Enum.join(Thread.visibilities(), ", ")}. " <>
        "A thread's visibility is the transparency tier that governs who may read its " <>
        "transcript: #{Thread.default_visibility()} keeps it to the account that opened it, " <>
        "and ledger opens it to any signed-in reader holding the thread id. " <>
        "The pulse and glass tiers of the shared vocabulary have no thread read path " <>
        "behind them, so this surface does not offer them."

    ApiError.refuse(conn, "thread_visibility_unsupported",
      message: sentence,
      errors: %{"visibility" => [sentence]}
    )
  end

  # The lane decides which door the model goes through. Absent means the
  # granted lane, exactly as every create before the field existed; a value
  # outside the admitted pair is refused rather than folded into a default,
  # because a caller that asked for a transcript-only thread and was minted a
  # grant — or the reverse — has no way to tell.
  defp lane(%{"lane" => value}) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed in Thread.lanes() do
      {:ok, trimmed}
    else
      {:refused, "lane",
       "#{inspect(trimmed)} is not an admitted lane. " <>
         "Admitted: #{Enum.join(Thread.lanes(), ", ")}."}
    end
  end

  defp lane(%{"lane" => value}) when not is_nil(value) do
    {:refused, "lane", "#{inspect(value)} is not a string."}
  end

  defp lane(_params), do: {:ok, Thread.default_lane()}

  defp shape_for("local", params), do: local_execution_shape(params)
  defp shape_for(_granted, params), do: execution_shape(params)

  # The local lane's model is the vendor string a local runtime serves —
  # `ollama:qwen3.8:27b-mtp-q8_0` — so it is bounded, not admitted: no catalog
  # membership and no provider availability, because no grant will ever carry
  # it to a provider (issue #243). It is required rather than defaulted: the
  # catalog default is a model this thread deliberately does not use, and
  # recording it would put a lie at the top of the transcript. The 200-byte
  # bound is the changeset's, the same one every thread's model column holds.
  defp local_execution_shape(params) do
    with {:ok, model} <- local_model(params),
         {:ok, reasoning} <-
           admitted(params, "reasoning", Thread.reasoning_efforts(), Threads.default_reasoning()),
         {:ok, profile} <-
           admitted(
             params,
             "permission_profile",
             Thread.permission_profiles(),
             Threads.default_permission_profile()
           ) do
      {:ok, [lane: "local", model: model, reasoning: reasoning, permission_profile: profile]}
    end
  end

  defp local_model(%{"model" => model}) when is_binary(model) do
    case String.trim(model) do
      "" ->
        {:refused, "model",
         "A local-lane thread records the model its local runtime serves, " <>
           "and the string cannot be blank."}

      trimmed ->
        {:ok, trimmed}
    end
  end

  defp local_model(%{"model" => model}) do
    {:refused, "model", "#{inspect(model)} is not a string."}
  end

  defp local_model(_params) do
    {:refused, "model",
     "A local-lane thread requires a model: the vendor string its local " <>
       "runtime serves, for example ollama:qwen3.8:27b-mtp-q8_0."}
  end

  defp execution_shape(params) do
    with {:ok, model} <- admitted(params, "model", Models.ids(), Models.default_id()),
         :ok <- serving(model),
         {:ok, reasoning} <-
           admitted(params, "reasoning", Thread.reasoning_efforts(), Threads.default_reasoning()),
         {:ok, profile} <-
           admitted(
             params,
             "permission_profile",
             Thread.permission_profiles(),
             Threads.default_permission_profile()
           ) do
      {:ok, [model: model, reasoning: reasoning, permission_profile: profile]}
    end
  end

  # An admitted model whose provider credential is not configured is refused
  # here rather than minted into a grant that can only fail at its first call
  # (PROVIDER-002): the catalog lists it as unavailable, and opening a thread
  # on it would be authority for work the deployment cannot do.
  defp serving(model_id) do
    case Models.fetch(model_id) do
      {:ok, model} ->
        if Models.available?(model), do: :ok, else: {:unavailable, model_id}

      # `admitted/4` has already bound the id to the catalog.
      :error ->
        {:unavailable, model_id}
    end
  end

  defp unavailable_model(conn, model_id) do
    sentence =
      "#{inspect(model_id)} is in the catalog but its provider is not configured " <>
        "on this deployment. Currently available: " <>
        "#{Enum.join(Models.available_ids(), ", ")}. See GET /api/v1/models."

    ApiError.refuse(conn, "model_unavailable",
      message: sentence,
      errors: %{"model" => [sentence]}
    )
  end

  # A value outside the enum is refused rather than replaced by the default: a
  # caller that asked for one execution shape and was given another has no way
  # to tell.
  defp admitted(params, key, admitted_values, default) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        if value in admitted_values do
          {:ok, value}
        else
          {:refused, key,
           "#{inspect(value)} is not an admitted #{key}. " <>
             "Admitted: #{Enum.join(admitted_values, ", ")}."}
        end

      value ->
        {:refused, key, "#{inspect(value)} is not a string."}
    end
  end

  # ── views ───────────────────────────────────────────────────────────────

  # The thread's `model` and its grant's are now the same admitted id, so only
  # the grant's is published: it is the one the request will actually use, and
  # printing the same name twice invites a reader to think they can differ.

  # The id is published because it is the cursor: a client continues from the
  # last one it read rather than counting.
  defp event_view(event) do
    %{
      "id" => event.id,
      "schema" => event.schema,
      "event_type" => event.event_type,
      "payload" => event.payload,
      "emitted_at" => stamp(event.emitted_at),
      "inserted_at" => stamp(event.inserted_at)
    }
  end

  defp thread_view(%Thread{} = thread) do
    %{
      "id" => thread.id,
      "status" => thread.status,
      "objective" => thread.objective,
      "repository" => thread.repository,
      "visibility" => thread.visibility,
      "reasoning_effort" => thread.reasoning_effort,
      "permission_profile" => thread.permission_profile,
      "generation" => thread.generation,
      "event_count" => thread.event_count,
      "report" => thread.report,
      "report_type" => thread.report_type,
      "error_code" => thread.error_code,
      "started_at" => stamp(thread.started_at),
      "completed_at" => stamp(thread.completed_at),
      # What the session cost, summed across every grant this thread has held
      # (#132). A resumed thread re-mints, so the live grant alone would
      # under-report; a dimension no provider gave is absent rather than zero.
      "spend" => spend_view(thread)
    }
  end

  defp spend_view(%Thread{} = thread) do
    spend = Threads.spend(thread)

    %{
      "calls" => spend.calls,
      "grants" => spend.grants,
      "usage" => spend.usage,
      # `cost.microusd` is null when any lane this session used has no declared
      # rates. A client that renders it as a currency has to handle the null
      # rather than print a zero it was never given (METER-001).
      "cost" => %{
        "microusd" => spend.cost.microusd,
        "priced_microusd" => spend.cost.priced_microusd,
        "basis" => spend.cost.basis,
        "unpriced_calls" => spend.cost.unpriced_calls,
        "unpriced_models" => spend.cost.unpriced_models
      }
    }
  end

  # The plaintext token exists exactly once, here. Everything else in this map
  # is what a client needs to spend it: where to send the call, which model the
  # proxy will pin, when the authority ends, and what it may spend.
  defp minted_view(%Grant{} = grant, token) do
    %{
      "token" => token,
      "url" => Inference.proxy_url(),
      "model" => grant.model_id,
      "expires_at" => stamp(grant.expires_at),
      "limits" => limits(grant)
    }
  end

  # A reader admitted by the thread's tier is not admitted to the owner's
  # balance. The tier discloses the transcript; the grant is what the account
  # is spending, and no rung of the ladder names it.
  defp grant_view(%Thread{}, :reader), do: nil
  defp grant_view(%Thread{} = thread, :owner), do: grant_view(Threads.latest_grant(thread))

  defp grant_view(nil), do: nil

  defp grant_view(%Grant{} = grant) do
    %{
      "status" => grant.status,
      "model" => grant.model_id,
      "expires_at" => stamp(grant.expires_at),
      "call_count" => grant.call_count,
      "usage" => grant.usage,
      "limits" => limits(grant),
      # What this grant was priced against, so the figures below can be
      # dereferenced rather than trusted. `unpriced` means the deployment has
      # no rates for this model: `spent_cost_microusd` is null, the cost
      # remainder is null, and neither is a zero (METER-001).
      "pricing" => %{
        "id" => Pricing.pricing_id_for(grant.model_id),
        "basis" => Pricing.basis(grant.model_id),
        "billable" => Pricing.billable?(grant.usage)
      },
      "spent" => %{
        "calls" => grant.call_count,
        "total_tokens" => spent(grant, "total_tokens"),
        "cost_microusd" => Pricing.cost(grant.usage)
      },
      "remaining" => %{
        "calls" => remaining(grant.max_calls, grant.call_count),
        "total_tokens" => remaining(grant.max_total_tokens, spent(grant, "total_tokens")),
        # An unpriced grant has no cost remainder to report. Subtracting a zero
        # from the ceiling would publish the whole ceiling as headroom on a
        # grant that has been spending all along.
        "cost_microusd" => cost_remaining(grant)
      }
    }
  end

  defp cost_remaining(%Grant{} = grant) do
    case Pricing.cost(grant.usage) do
      nil -> nil
      cost -> remaining(grant.max_cost_microusd, cost)
    end
  end

  defp limits(%Grant{} = grant) do
    %{
      "max_calls" => grant.max_calls,
      "max_total_tokens" => grant.max_total_tokens,
      "max_cost_microusd" => grant.max_cost_microusd
    }
  end

  defp spent(%Grant{usage: usage}, key) when is_map(usage) do
    case Map.get(usage, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _absent -> 0
    end
  end

  defp spent(_grant, _key), do: 0

  # An unbounded ceiling has no remainder to report. `null` is what the client
  # already reads for "no limit" in `limits`, and reporting a number here would
  # have meant inventing one.
  defp remaining(nil, _spent), do: nil
  defp remaining(ceiling, spent), do: max(ceiling - spent, 0)

  defp stamp(nil), do: nil
  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp put_extension_header(conn),
    do: put_resp_header(conn, "x-openagents-extensions", @extension)
end
