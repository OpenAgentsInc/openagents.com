defmodule OpenAgentsWeb.ThreadController do
  @moduledoc """
  The door to a thread: open one, read what it has spent, revoke it.

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

  The model is admitted here and nowhere else. A request body sent to the proxy
  still cannot select a model — the proxy pins the grant's — so the one place a
  caller states which model it wants is the thread it opens, and the response
  publishes the model the grant carries. Admitting it at the door is what lets
  a coding session run its own turns on one model and its delegated children on
  another: it opens a second thread on `ox-alpha` and gets authority for
  `ox-alpha`, with its own budget, rather than borrowing the first thread's.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Conversations
  alias OpenAgents.Inference
  alias OpenAgents.Inference.{Credit, Grant, Models}
  alias OpenAgents.Threads
  alias OpenAgents.Threads.Thread
  alias OpenAgentsWeb.ApiError

  @extension "thread.openagents"

  def create(conn, params) do
    with {:ok, objective} <- objective(params),
         {:ok, options} <- execution_shape(params) do
      open(conn, objective, options)
    else
      {:refused, field, message} -> ApiError.validation_failed(conn, %{field => [message]})
    end
  end

  def show(conn, %{"thread_id" => thread_id}) do
    with_thread(conn, thread_id, fn thread -> render_thread(conn, :ok, thread) end)
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

  # The refusal names the ceiling and the account's own count, so a client that
  # scripts several checkouts learns what to close rather than what to retry.
  defp quota_reached(conn) do
    limit = Threads.maximum_open_per_account()
    held = Threads.open_count(conn.assigns.current_user)

    sentence =
      "This account holds #{held} open threads and the configured maximum is #{limit}. " <>
        "Revoke a thread with DELETE /api/v3/threads/{thread_id} before opening another."

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
  defp with_thread(conn, thread_id, continue) do
    user = conn.assigns.current_user
    _reaped = Threads.reap_expired(user)

    case Threads.get_for_user(user, thread_id) do
      %Thread{} = thread -> continue.(thread)
      nil -> ApiError.not_found(conn)
    end
  end

  defp render_thread(conn, status, %Thread{} = thread) do
    conn
    |> put_extension_header()
    |> put_status(status)
    |> json(%{
      "thread" => thread_view(thread),
      "grant" => grant_view(Threads.latest_grant(thread))
    })
  end

  # ── parameters ──────────────────────────────────────────────────────────

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

  defp execution_shape(params) do
    with {:ok, model} <- admitted(params, "model", Models.ids(), Models.default_id()),
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

  defp thread_view(%Thread{} = thread) do
    %{
      "id" => thread.id,
      "status" => thread.status,
      "objective" => thread.objective,
      "reasoning_effort" => thread.reasoning_effort,
      "permission_profile" => thread.permission_profile,
      "generation" => thread.generation,
      "event_count" => thread.event_count,
      "report" => thread.report,
      "error_code" => thread.error_code,
      "started_at" => stamp(thread.started_at),
      "completed_at" => stamp(thread.completed_at)
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

  defp grant_view(nil), do: nil

  defp grant_view(%Grant{} = grant) do
    %{
      "status" => grant.status,
      "model" => grant.model_id,
      "expires_at" => stamp(grant.expires_at),
      "call_count" => grant.call_count,
      "usage" => grant.usage,
      "limits" => limits(grant),
      "remaining" => %{
        "calls" => remaining(grant.max_calls, grant.call_count),
        "total_tokens" => remaining(grant.max_total_tokens, spent(grant, "total_tokens")),
        "cost_microusd" =>
          remaining(grant.max_cost_microusd, spent(grant, "estimated_cost_microusd"))
      }
    }
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

  defp remaining(ceiling, spent), do: max(ceiling - spent, 0)

  defp stamp(nil), do: nil
  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp put_extension_header(conn),
    do: put_resp_header(conn, "x-openagents-extensions", @extension)
end
