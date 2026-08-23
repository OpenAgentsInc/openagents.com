defmodule OpenAgents.Inference do
  @moduledoc """
  Server-minted inference grants and their accounting.

  This is the funnel inversion in one context: instead of a coding agent
  holding a provider key and metering through a vendor gateway, Sarah mints a
  short-lived, budgeted, generation-fenced grant, hands only the opaque token
  to the delegation, and every model call the agent makes flows back through
  the Sarah inference proxy — fanned into the configured
  `OpenAgents.Providers.Provider` (PROVIDER-001), the OpenAI credential never
  leaving the server (RELEASE-002), usage metered against the owner's account
  in the voice-runtime pattern (VOICE-002/VOICE-010).

  "Free coding agent with free inference" is then a pricing decision: the
  ceilings here are the abuse backstop, not the product boundary.
  """

  import Ecto.Query
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Repo

  @token_prefix "sig_"

  @type ceilings :: %{
          required(:max_total_tokens) => pos_integer(),
          required(:max_calls) => pos_integer(),
          required(:max_cost_microusd) => pos_integer(),
          required(:ttl_seconds) => pos_integer()
        }

  @type mint_input :: %{
          required(:owner_visitor_id) => String.t(),
          optional(:conversation_id) => String.t() | nil,
          optional(:thread_id) => String.t() | nil,
          optional(:machine_id) => String.t() | nil,
          optional(:ceilings) => ceilings()
        }

  @doc """
  Mint a grant for one bounded body of work. Returns `{:ok, grant, token}`
  where `token` is the ONLY time the plaintext exists — the caller injects it
  into the probe process and it is never stored, logged, or recoverable.

  The input names exactly one fence: `:thread_id` for a thread, or
  `:conversation_id` for the account conversation. Both, or neither, is refused
  by the changeset and independently by PostgreSQL (THREAD-001).

  The input may also name its own `:ceilings`. Without them a grant takes the
  delegation ceilings, which bound one probe run the server already admitted.
  A thread's budget is a different question — the caller asked for it, and it
  lives as long as someone is working — so `OpenAgents.Threads` passes
  `OpenAgents.Threads.ceilings/0` rather than borrowing these numbers.
  """
  @spec mint(mint_input()) :: {:ok, Grant.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def mint(%{} = input) do
    token = @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    ceilings = Map.get(input, :ceilings) || delegation_ceilings()

    attrs = %{
      owner_visitor_id: input.owner_visitor_id,
      conversation_id: Map.get(input, :conversation_id),
      thread_id: Map.get(input, :thread_id),
      machine_id: Map.get(input, :machine_id),
      model_id: model_id(),
      token_digest: digest(token),
      max_total_tokens: ceilings.max_total_tokens,
      max_calls: ceilings.max_calls,
      max_cost_microusd: ceilings.max_cost_microusd,
      expires_at: DateTime.add(now(), ceilings.ttl_seconds, :second)
    }

    case attrs |> Grant.mint_changeset() |> Repo.insert() do
      {:ok, grant} -> {:ok, grant, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Resolve a plaintext grant token to a usable grant, or a typed refusal.

  Fails closed: unknown, revoked, exhausted, expired, or over-budget grants
  never authorize a call. A grant found past its expiry is transitioned to
  `expired` before refusal.
  """
  @spec resolve(String.t()) ::
          {:ok, Grant.t()}
          | {:error,
             :grant_not_found
             | :grant_revoked
             | :grant_exhausted
             | :grant_expired
             | :grant_budget_reached}
  def resolve(token) when is_binary(token) do
    case Repo.get_by(Grant, token_digest: digest(token)) do
      nil ->
        {:error, :grant_not_found}

      %Grant{status: "revoked"} ->
        {:error, :grant_revoked}

      %Grant{status: "exhausted"} ->
        {:error, :grant_exhausted}

      %Grant{status: "expired"} ->
        {:error, :grant_expired}

      %Grant{status: "active"} = grant ->
        cond do
          DateTime.compare(now(), grant.expires_at) != :lt ->
            _ = expire(grant)
            {:error, :grant_expired}

          over_budget?(grant) ->
            {:error, :grant_budget_reached}

          true ->
            {:ok, grant}
        end
    end
  end

  def resolve(_), do: {:error, :grant_not_found}

  @doc """
  Record usage for one metered call and advance the grant. Merges provider
  token usage, prices it, increments the call count, and flips the grant to
  `exhausted` when any ceiling is reached — atomically, re-reading under a row
  lock so concurrent calls cannot exceed the budget.
  """
  @spec record_usage(Grant.t(), map()) :: {:ok, Grant.t()} | {:error, term()}
  def record_usage(%Grant{id: id}, provider_usage) when is_map(provider_usage) do
    Repo.transaction(fn ->
      grant =
        Grant
        |> where([g], g.id == ^id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case grant do
        %Grant{status: "active"} = grant ->
          merged = merge_usage(grant.usage, provider_usage)
          would_exhaust = would_exhaust?(grant, merged)
          next_status = if would_exhaust, do: "exhausted", else: "active"

          grant
          |> Grant.usage_changeset(merged, next_status, now())
          |> Repo.update()
          |> case do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end

        _terminal ->
          Repo.rollback(:grant_not_active)
      end
    end)
  end

  @doc "Revoke a grant. Idempotent for already-terminal grants."
  @spec revoke(Grant.t()) :: {:ok, Grant.t()} | {:error, term()}
  def revoke(%Grant{status: "active"} = grant) do
    grant |> Grant.terminal_changeset("revoked", now()) |> Repo.update()
  end

  def revoke(%Grant{} = grant), do: {:ok, grant}

  @doc """
  Revoke every active grant for a thread.

  This is the thread's generation fence, and unlike the conversation function
  below it has callers: `OpenAgents.Threads.mint_grant/1` runs it before every
  mint, and every terminal transition in `OpenAgents.Threads` runs it inside the
  transaction that writes the terminal row. A thread therefore has at most one
  live grant, and a terminal thread has none.
  """
  @spec revoke_active_for_thread(String.t()) :: {non_neg_integer(), nil}
  def revoke_active_for_thread(thread_id) when is_binary(thread_id) do
    stamp = now()

    Grant
    |> where([g], g.thread_id == ^thread_id and g.status == "active")
    |> Repo.update_all(set: [status: "revoked", revoked_at: stamp, updated_at: stamp])
  end

  def revoke_active_for_thread(_), do: {0, nil}

  @doc """
  Expire every one of an owner's active grants whose clock has run out.

  `resolve/1` already expires a grant the moment somebody presents it, which is
  enough to refuse the call and no help to anything that reads the ledger
  instead. This is the same transition without a bearer: an elapsed grant stops
  being reported as live, stops holding a thread's single active-grant slot,
  and stops counting against the account's admission cap, whether or not anyone
  ever presents the token again.
  """
  @spec expire_elapsed_for_owner(String.t()) :: {non_neg_integer(), nil}
  def expire_elapsed_for_owner(owner_visitor_id) when is_binary(owner_visitor_id) do
    stamp = now()

    Grant
    |> where([g], g.owner_visitor_id == ^owner_visitor_id)
    |> where([g], g.status == "active" and g.expires_at <= ^stamp)
    |> Repo.update_all(set: [status: "expired", exhausted_at: stamp, updated_at: stamp])
  end

  def expire_elapsed_for_owner(_), do: {0, nil}

  @doc "The ceilings a grant takes when its caller names none."
  @spec delegation_ceilings() :: ceilings()
  def delegation_ceilings do
    %{
      max_total_tokens: max_total_tokens(),
      max_calls: max_calls(),
      max_cost_microusd: max_cost_microusd(),
      ttl_seconds: grant_ttl_seconds()
    }
  end

  @doc "Revoke every active grant for a conversation (generation fence on a new turn/delegation)."
  @spec revoke_active_for_conversation(String.t()) :: {non_neg_integer(), nil}
  def revoke_active_for_conversation(conversation_id) when is_binary(conversation_id) do
    stamp = now()

    Grant
    |> where([g], g.conversation_id == ^conversation_id and g.status == "active")
    |> Repo.update_all(set: [status: "revoked", revoked_at: stamp, updated_at: stamp])
  end

  def revoke_active_for_conversation(_), do: {0, nil}

  @doc "The proxy endpoint URL a probe delegation should target."
  @spec proxy_url() :: String.t()
  def proxy_url do
    Application.get_env(:openagents, :inference_proxy_url) || default_proxy_url()
  end

  # ── budget ──────────────────────────────────────────────────────────────

  @doc false
  def over_budget?(%Grant{} = grant) do
    tokens = integer(grant.usage["total_tokens"])
    cost = integer(grant.usage["estimated_cost_microusd"])

    grant.call_count >= grant.max_calls or
      tokens >= grant.max_total_tokens or
      cost >= grant.max_cost_microusd
  end

  defp would_exhaust?(%Grant{} = grant, merged) do
    tokens = integer(merged["total_tokens"])
    cost = integer(merged["estimated_cost_microusd"])

    grant.call_count + 1 >= grant.max_calls or
      tokens >= grant.max_total_tokens or
      cost >= grant.max_cost_microusd
  end

  # ── usage accounting (voice Usage pattern) ──────────────────────────────

  @usage_schema "sarah.inference_grant_usage.v1"
  @cost_fields ~w(input_tokens output_tokens total_tokens reasoning_tokens
                  cache_read_input_tokens cache_write_input_tokens)

  @doc false
  def merge_usage(existing, provider_usage) do
    normalized = normalize_usage(provider_usage)

    merged =
      Enum.reduce(@cost_fields, %{}, fn field, acc ->
        Map.put(acc, field, integer(existing[field]) + integer(normalized[field]))
      end)

    merged
    |> Map.put("total_tokens", derived_total(existing, merged))
    |> put_cost(existing)
    |> Map.put("schema", @usage_schema)
  end

  defp derived_total(existing, merged) do
    explicit = integer(merged["total_tokens"])

    if explicit > integer(existing["total_tokens"]) do
      explicit
    else
      integer(merged["input_tokens"]) + integer(merged["output_tokens"])
    end
  end

  defp put_cost(merged, _existing) do
    cost =
      integer(merged["input_tokens"]) * input_price_microusd() +
        integer(merged["output_tokens"]) * output_price_microusd()

    Map.put(merged, "estimated_cost_microusd", div(cost, 1_000))
  end

  defp normalize_usage(usage) do
    Enum.reduce(@cost_fields, %{}, fn field, acc ->
      Map.put(acc, field, integer(usage[field] || usage[String.to_atom(field)]))
    end)
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp expire(%Grant{} = grant) do
    grant |> Grant.terminal_changeset("expired", now()) |> Repo.update()
  end

  defp digest(token), do: :crypto.hash(:sha256, token)

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: trunc(value)

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp integer(_), do: 0

  defp now, do: DateTime.utc_now()

  defp model_id, do: Application.fetch_env!(:openagents, :openai_model)

  defp max_total_tokens,
    do: Application.get_env(:openagents, :inference_grant_max_total_tokens, 2_000_000)

  defp max_calls, do: Application.get_env(:openagents, :inference_grant_max_calls, 64)

  defp max_cost_microusd,
    do: Application.get_env(:openagents, :inference_grant_max_cost_microusd, 5_000_000)

  defp grant_ttl_seconds, do: Application.get_env(:openagents, :inference_grant_ttl_seconds, 900)

  defp input_price_microusd,
    do: Application.get_env(:openagents, :inference_input_price_microusd_per_ktoken, 1_250)

  defp output_price_microusd,
    do: Application.get_env(:openagents, :inference_output_price_microusd_per_ktoken, 10_000)

  defp default_proxy_url do
    endpoint = OpenAgentsWeb.Endpoint.url()
    endpoint <> "/api/inference/proxy"
  end
end
