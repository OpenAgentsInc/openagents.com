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
  alias OpenAgents.Inference.{Grant, Models, Pricing}
  alias OpenAgents.Machines.Machine
  alias OpenAgents.Repo

  @token_prefix "sig_"

  @type ceilings :: %{
          required(:max_total_tokens) => pos_integer() | nil,
          required(:max_calls) => pos_integer() | nil,
          required(:max_cost_microusd) => pos_integer() | nil,
          # nil is unbounded, on every one of these. A grant with no ceilings
          # and no clock is bounded by revocation alone, which is what a
          # thread's grant is.
          required(:ttl_seconds) => pos_integer() | nil
        }

  @type mint_input :: %{
          required(:owner_visitor_id) => String.t(),
          optional(:conversation_id) => String.t() | nil,
          optional(:thread_id) => String.t() | nil,
          optional(:machine_id) => String.t() | nil,
          optional(:model_id) => String.t() | nil,
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

  The input may name its own `:model_id`. Without one a grant takes
  `OpenAgents.Inference.Models.default_id/0`, and a name the proxy cannot route
  is refused here rather than at the first call.

  A grant that names a computer is minted only while that computer is active,
  and only inside the transaction that established it (IDENTITY-008). A revoked
  computer answers `{:error, :machine_revoked}`.
  """
  @spec mint(mint_input()) ::
          {:ok, Grant.t(), String.t()} | {:error, Ecto.Changeset.t() | :machine_revoked}
  def mint(%{} = input) do
    case model_id(Map.get(input, :model_id)) do
      {:ok, model_id} -> mint(input, model_id)
      :error -> {:error, unadmitted_model(Map.get(input, :model_id))}
    end
  end

  defp mint(%{} = input, model_id) do
    token = @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    ceilings = Map.get(input, :ceilings) || delegation_ceilings()

    attrs = %{
      owner_visitor_id: input.owner_visitor_id,
      conversation_id: Map.get(input, :conversation_id),
      thread_id: Map.get(input, :thread_id),
      machine_id: Map.get(input, :machine_id),
      model_id: model_id,
      token_digest: digest(token),
      max_total_tokens: ceilings.max_total_tokens,
      max_calls: ceilings.max_calls,
      max_cost_microusd: ceilings.max_cost_microusd,
      expires_at: deadline(ceilings)
    }

    changeset = Grant.mint_changeset(attrs)

    case Map.get(input, :machine_id) do
      nil ->
        case Repo.insert(changeset) do
          {:ok, grant} -> {:ok, grant, token}
          {:error, changeset} -> {:error, changeset}
        end

      machine_id ->
        mint_for_computer(changeset, machine_id, token)
    end
  end

  # A computer-bound grant is minted inside the transaction that reads its
  # computer's row under `FOR SHARE`. `OpenAgents.Machines.revoke_machine/2`
  # takes a conflicting lock on that row before it sweeps the computer's active
  # grants, so a mint and a revocation cannot interleave: a mint that gets there
  # first is found by the sweep, and one that gets there second reads `revoked`
  # and is refused. The same read runs in `inference_grants_refuse_revoked_computer`
  # for every other writer, because a source scan finds call sites and not
  # values.
  defp mint_for_computer(changeset, machine_id, token) do
    Repo.transaction(fn ->
      case computer_status(machine_id) do
        "active" ->
          case Repo.insert(changeset) do
            {:ok, grant} -> grant
            {:error, invalid} -> Repo.rollback(invalid)
          end

        _absent_or_terminal ->
          Repo.rollback(:machine_revoked)
      end
    end)
    |> case do
      {:ok, grant} -> {:ok, grant, token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp computer_status(machine_id) do
    case Ecto.UUID.cast(machine_id) do
      {:ok, id} ->
        Machine
        |> where([m], m.id == ^id)
        |> lock("FOR SHARE")
        |> select([m], m.status)
        |> Repo.one()

      :error ->
        nil
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
          # A grant with no clock cannot elapse. `DateTime.compare/2` would
          # raise on nil rather than answer, so the absence is read first.
          not is_nil(grant.expires_at) and DateTime.compare(now(), grant.expires_at) != :lt ->
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

  `served` names the model that actually answered, because the grant's model is
  what was asked for and the two are not always the same name. `:requested`
  says the lane cannot be substituted for, so the grant's model served it.
  `:unresolved` says the lane can be substituted for and the response did not
  disclose what answered, which is priced at nothing rather than at the
  requested model's rate. A binary is the serving model's own name (METER-001).
  """
  @spec record_usage(Grant.t(), map()) :: {:ok, Grant.t()} | {:error, term()}
  def record_usage(%Grant{} = grant, provider_usage) when is_map(provider_usage),
    do: record_usage(grant, provider_usage, :requested)

  @spec record_usage(Grant.t(), map(), :requested | :unresolved | String.t()) ::
          {:ok, Grant.t()} | {:error, term()}
  def record_usage(%Grant{id: id}, provider_usage, served)
      when is_map(provider_usage) and (served in [:requested, :unresolved] or is_binary(served)) do
    Repo.transaction(fn ->
      grant =
        Grant
        |> where([g], g.id == ^id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case grant do
        %Grant{status: "active"} = grant ->
          merged = merge_usage(grant.usage, provider_usage, served_name(served, grant.model_id))
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
    |> case do
      {:ok, %Grant{thread_id: thread_id} = updated} ->
        # A thread grant's usage is a leaderboard plane (LEADERBOARD-001), so
        # this is the one place a thread's token total can change. Conversation
        # grants are not counted there and stay silent.
        if is_binary(thread_id), do: :ok = OpenAgents.Leaderboard.invalidate()
        {:ok, updated}

      {:error, _reason} = error ->
        error
    end
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
  Revoke every active grant minted for a computer.

  A grant's plaintext token is on the computer from the moment it is minted, so
  closing the computer's channel and finishing its assignments does not stop it
  spending — `OpenAgentsWeb.InferenceProxyController` authenticates the token
  and nothing else. This is the transition that does, and
  `OpenAgents.Machines.revoke_machine/2` runs it inside the transaction that
  writes the revoked computer row (IDENTITY-008).

  It moves `status` and the terminal stamp and nothing else. A grant's fences —
  `conversation_id`, `thread_id`, and `machine_id` — stay immutable under the
  `inference_grants` update trigger, so revoking a computer cannot become a way
  to acquire, exchange, or shed the fence THREAD-001 requires.
  """
  @spec revoke_active_for_machine(String.t()) :: {non_neg_integer(), nil}
  def revoke_active_for_machine(machine_id) when is_binary(machine_id) do
    stamp = now()

    Grant
    |> where([g], g.machine_id == ^machine_id and g.status == "active")
    |> Repo.update_all(set: [status: "revoked", revoked_at: stamp, updated_at: stamp])
  end

  def revoke_active_for_machine(_), do: {0, nil}

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
    |> where([g], g.status == "active" and not is_nil(g.expires_at) and g.expires_at <= ^stamp)
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

  # A cost ceiling can only stop spend it can measure. An unpriced model writes
  # no `estimated_cost_microusd`, so `max_cost_microusd` never fires for it and
  # such a grant is bounded by its call and token ceilings, by the account's
  # admission cap, and by revocation — not by money. That is a consequence of
  # not knowing the rates rather than a decision to let the lane run free, and
  # it is why `Threads.spend/1` and `Credit.unpriced_calls/1` publish the
  # unpriced calls instead of folding them into a total (METER-001).

  @doc false
  def over_budget?(%Grant{} = grant) do
    tokens = integer(grant.usage["total_tokens"])
    cost = integer(grant.usage["estimated_cost_microusd"])

    reached?(grant.call_count, grant.max_calls) or
      reached?(tokens, grant.max_total_tokens) or
      reached?(cost, grant.max_cost_microusd)
  end

  defp would_exhaust?(%Grant{} = grant, merged) do
    tokens = integer(merged["total_tokens"])
    cost = integer(merged["estimated_cost_microusd"])

    reached?(grant.call_count + 1, grant.max_calls) or
      reached?(tokens, grant.max_total_tokens) or
      reached?(cost, grant.max_cost_microusd)
  end

  # A ceiling that was never set cannot be reached. Comparing against nil would
  # raise in Elixir's term order rather than answer — `1 >= nil` is false, which
  # would have read as "not reached" by accident rather than by decision.
  defp reached?(_spent, nil), do: false
  defp reached?(spent, ceiling), do: spent >= ceiling

  # ── usage accounting (voice Usage pattern) ──────────────────────────────

  @usage_schema "sarah.inference_grant_usage.v1"
  @cost_fields ~w(input_tokens output_tokens total_tokens reasoning_tokens
                  cache_read_input_tokens cache_write_input_tokens)

  # The two names a usage record's `served_model` can carry that are not a
  # model. Neither resolves in the catalog, so `Pricing.price/2` prices both at
  # nothing — which is the point: an unknown is not a rate.
  @unresolved_model "unresolved"
  @mixed_model "mixed"

  @doc "What a usage record's `served_model` says when the provider disclosed nothing."
  @spec unresolved_model() :: String.t()
  def unresolved_model, do: @unresolved_model

  @doc "What a usage record's `served_model` says when more than one model served it."
  @spec mixed_model() :: String.t()
  def mixed_model, do: @mixed_model

  defp served_name(:requested, model_id), do: model_id
  defp served_name(:unresolved, _model_id), do: @unresolved_model
  defp served_name(name, _model_id) when is_binary(name), do: name

  @doc """
  Merge one call's provider usage into a grant's record and price the total.

  `served_model_name` is the model that answered this call. A record is priced
  against the model that served it, never against the one that was asked for,
  and a record whose calls were served by more than one model is priced at
  nothing: a single total cannot be charged at two rates, and picking one would
  be a guess (METER-001).
  """
  @spec merge_usage(map() | nil, map(), String.t() | nil) :: map()
  def merge_usage(existing, provider_usage, served_model_name) do
    normalized = normalize_usage(provider_usage)
    served = served_model(existing, served_model_name)

    merged =
      Enum.reduce(@cost_fields, %{}, fn field, acc ->
        case {existing[field], normalized[field]} do
          {nil, nil} ->
            acc

          {existing_value, nil} ->
            Map.put(acc, field, integer(existing_value))

          {nil, normalized_value} ->
            Map.put(acc, field, integer(normalized_value))

          {existing_value, normalized_value} ->
            Map.put(acc, field, integer(existing_value) + integer(normalized_value))
        end
      end)

    merged
    |> Map.put("total_tokens", derived_total(existing, merged))
    |> Map.put("served_model", served)
    |> Pricing.price(served)
    |> Map.put("schema", @usage_schema)
  end

  # The model a record says served it. A record already naming one model that
  # a later call did not use becomes `mixed`, because the accumulated total is
  # then a sum across two rate tables and no single one prices it.
  #
  # A record written before this key existed names nothing, so the first call
  # after that names the model that served it. That is the honest reading:
  # nothing recorded which model served the earlier calls, and inventing an
  # agreement in order to keep a price would be the failure this exists to
  # prevent.
  defp served_model(existing, name) do
    name = canonical_model(name)

    case Map.get(existing || %{}, "served_model") do
      nil -> name
      ^name -> name
      _different -> @mixed_model
    end
  end

  # One model, one name. A provider reports the vendor spelling
  # (`google/gemini-3.7-flash`) and a grant may carry either, so both are
  # written as the catalog id — otherwise two spellings of one model would read
  # as two models and make a record `mixed` that never left its lane. A name
  # the catalog does not serve stays as it came, which is exactly the case that
  # prices at nothing.
  defp canonical_model(nil), do: @unresolved_model

  defp canonical_model(name) when is_binary(name) do
    case Models.fetch(name) do
      {:ok, %{id: id}} -> id
      :error -> name
    end
  end

  defp derived_total(existing, merged) do
    explicit = integer(merged["total_tokens"])

    if explicit > integer(existing["total_tokens"]) do
      explicit
    else
      integer(merged["input_tokens"]) + integer(merged["output_tokens"])
    end
  end

  defp normalize_usage(usage) do
    Enum.reduce(@cost_fields, %{}, fn field, acc ->
      case raw_value(usage, field) do
        nil -> acc
        value -> Map.put(acc, field, integer(value))
      end
    end)
  end

  defp raw_value(usage, field) do
    case usage[field] do
      nil -> usage[String.to_atom(field)]
      value -> value
    end
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

  # A grant may pin only a model the proxy can route, so an unadmitted name is
  # refused at the mint rather than at the first call: a token that cannot be
  # spent is worse than no token, because its holder learns that only after
  # believing it had authority.
  defp model_id(nil), do: {:ok, Models.default_id()}

  defp model_id(requested) do
    case Models.fetch(requested) do
      {:ok, model} -> {:ok, model.id}
      :error -> :error
    end
  end

  defp unadmitted_model(requested) do
    sentence =
      "#{inspect(requested)} is not a model this proxy routes. " <>
        "Admitted: #{Enum.join(Models.ids(), ", ")}."

    # Only the model is reported. Running the full mint changeset here would
    # answer a wrong model name with a list of every field the caller never
    # sent, burying the one thing it can fix.
    %Grant{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:model_id, sentence)
  end

  defp max_total_tokens,
    do: Application.get_env(:openagents, :inference_grant_max_total_tokens, 2_000_000)

  defp max_calls, do: Application.get_env(:openagents, :inference_grant_max_calls, 64)

  defp max_cost_microusd,
    do: Application.get_env(:openagents, :inference_grant_max_cost_microusd, 5_000_000)

  defp grant_ttl_seconds, do: Application.get_env(:openagents, :inference_grant_ttl_seconds, 900)

  # nil ttl means no deadline at all, rather than one computed from nil.
  defp deadline(%{ttl_seconds: nil}), do: nil
  defp deadline(%{ttl_seconds: seconds}), do: DateTime.add(now(), seconds, :second)

  defp default_proxy_url do
    endpoint = OpenAgentsWeb.Endpoint.url()
    endpoint <> "/api/inference/proxy"
  end
end
