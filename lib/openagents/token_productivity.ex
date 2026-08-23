defmodule OpenAgents.TokenProductivity do
  @moduledoc """
  Productive token accounting: raw volume versus tokens that produced durable
  outcomes.

  Raw volume alone rewards burn. This module reads the four tables that hold
  token truth — `turn_receipts`, `voice_sessions`, `work_jobs`, and `scv_runs`
  — and splits the same tokens a second way: how many are attached to evidence
  that the work landed. Three buckets, strongest evidence first, each usage
  row counted at most once:

    * **Merged work** — an SCV run whose issue carries a merged pull request.
    * **Closed issues** — an SCV run whose issue closed without a merged pull
      request.
    * **Verified receipts** — an SCV run that succeeded with a digest-verified
      terminal receipt, or a work job that completed with its bounded report,
      where no stronger outcome evidence exists.

  Typed and spoken conversation tokens count toward raw volume only: a chat
  turn has no durable outcome record to attribute it to.

  ## Which usage counts

  The same double-count rule as `OpenAgents.Leaderboard` applies:
  `turn_receipts.usage` is already the merge of every tool-loop provider call
  in a typed turn, and `voice_sessions.usage` is already the merge of that
  session's responses, so `turn_provider_steps.usage` is never summed into raw
  totals. Provider steps are read separately — and only for the per-provider
  throughput table, where attributing tokens to the provider that produced
  them is the whole point. `work_jobs` rows come from the OpenCode-driven work
  machinery and `scv_runs` rows from the Codex driver; the two never describe
  the same run.

  ## Rates

  Stored usage maps spell their cache field three ways: `cached_input_tokens`
  (typed turns, Codex runs) and `input_cached_tokens` (voice) count cached
  tokens inside `input_tokens`, while `cache_read_tokens` (OpenCode) counts
  them separately. The cache hit rate therefore divides all cached tokens by
  `input_tokens` plus the exclusive `cache_read_tokens`, so both spellings
  land in the same denominator. The input share uses that same inclusive
  input count over input plus output.
  """

  import Ecto.Query

  alias OpenAgents.Conversations.ProviderStep
  alias OpenAgents.Conversations.TurnReceipt
  alias OpenAgents.Issues.Issue
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.SCV.Execution
  alias OpenAgents.Voice.Session
  alias OpenAgents.Work.Job

  @schema "openagents.token_productivity.v1"

  @empty_totals %{
    input_tokens: 0,
    output_tokens: 0,
    cached_input_tokens: 0,
    cache_read_tokens: 0,
    total_tokens: 0
  }

  @type totals :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @type provider_row :: %{
          provider_id: String.t(),
          steps: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          duration_ms: non_neg_integer(),
          tokens_per_second: float() | nil
        }

  @type report :: %{
          schema: String.t(),
          generated_at: DateTime.t(),
          raw: totals(),
          sources: %{
            typed_turns: totals(),
            voice_sessions: totals(),
            work_jobs: totals(),
            scv_runs: totals()
          },
          productive: %{
            merged_work: totals(),
            closed_issues: totals(),
            verified_receipts: totals(),
            total_tokens: non_neg_integer(),
            share: float() | nil
          },
          cache: %{
            cached_input_tokens: non_neg_integer(),
            input_tokens: non_neg_integer(),
            hit_rate: float() | nil
          },
          split: %{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            input_share: float() | nil
          },
          providers: [provider_row()]
        }

  # SUM of one numeric JSON field, defensive against absent keys and
  # non-numeric values, exactly like the leaderboard's usage fragments. The
  # key is a compile-time literal, inlined so the operator stays jsonb ->> text.
  defmacrop summed(usage, key) when is_binary(key) do
    expression =
      "COALESCE(SUM(CASE WHEN ? ->> '#{key}' ~ '^[0-9]+$' THEN (? ->> '#{key}')::bigint ELSE 0 END), 0)"

    quote do
      fragment(unquote(expression), unquote(usage), unquote(usage))
    end
  end

  # Per-row effective total: providers that omit total_tokens still count.
  defmacrop summed_effective_total(usage) do
    quote do
      fragment(
        """
        COALESCE(SUM(GREATEST(
          CASE WHEN ? ->> 'total_tokens' ~ '^[0-9]+$' THEN (? ->> 'total_tokens')::bigint ELSE 0 END,
          CASE WHEN ? ->> 'input_tokens' ~ '^[0-9]+$' THEN (? ->> 'input_tokens')::bigint ELSE 0 END
            + CASE WHEN ? ->> 'output_tokens' ~ '^[0-9]+$' THEN (? ->> 'output_tokens')::bigint ELSE 0 END
        )), 0)
        """,
        unquote(usage),
        unquote(usage),
        unquote(usage),
        unquote(usage),
        unquote(usage),
        unquote(usage)
      )
    end
  end

  @doc "Computes the full report straight from PostgreSQL."
  @spec report() :: report()
  def report do
    sources = %{
      typed_turns: totals(from(receipt in TurnReceipt, as: :usage_row)),
      voice_sessions: totals(from(session in Session, as: :usage_row)),
      work_jobs: totals(from(job in Job, as: :usage_row)),
      scv_runs: totals(from(run in Execution, as: :usage_row))
    }

    raw =
      Enum.reduce(Map.values(sources), @empty_totals, &merge_totals/2)

    merged_work = totals(merged_work_query())
    closed_issues = totals(closed_issues_query())

    verified_receipts =
      merge_totals(totals(receipt_runs_query()), totals(completed_jobs_query()))

    productive_total =
      merged_work.total_tokens + closed_issues.total_tokens + verified_receipts.total_tokens

    cached = raw.cached_input_tokens
    input_inclusive = raw.input_tokens + raw.cache_read_tokens

    %{
      schema: @schema,
      generated_at: DateTime.utc_now(),
      raw: raw,
      sources: sources,
      productive: %{
        merged_work: merged_work,
        closed_issues: closed_issues,
        verified_receipts: verified_receipts,
        total_tokens: productive_total,
        share: ratio(productive_total, raw.total_tokens)
      },
      cache: %{
        cached_input_tokens: cached,
        input_tokens: input_inclusive,
        hit_rate: ratio(cached, input_inclusive)
      },
      split: %{
        input_tokens: input_inclusive,
        output_tokens: raw.output_tokens,
        input_share: ratio(input_inclusive, input_inclusive + raw.output_tokens)
      },
      providers: providers()
    }
  end

  @doc """
  Per-provider volume and throughput from completed provider steps.

  Provider steps carry each attempt's own usage and wall clock, so this is the
  one place they are read: tokens per second come from output tokens over the
  step's recorded duration.
  """
  @spec providers() :: [provider_row()]
  def providers do
    from(step in ProviderStep,
      as: :usage_row,
      where: step.status == "completed" and not is_nil(step.usage),
      group_by: step.provider_id,
      order_by: [desc: summed_effective_total(step.usage)],
      select: %{
        provider_id: step.provider_id,
        steps: count(step.id),
        input_tokens: summed(step.usage, "input_tokens"),
        output_tokens: summed(step.usage, "output_tokens"),
        cached_input_tokens: summed(step.usage, "cached_input_tokens"),
        total_tokens: summed_effective_total(step.usage),
        duration_ms:
          fragment(
            "COALESCE(SUM(EXTRACT(EPOCH FROM (? - ?)) * 1000) FILTER (WHERE ? IS NOT NULL), 0)::bigint",
            step.completed_at,
            step.started_at,
            step.completed_at
          )
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      row =
        Map.new(row, fn
          {:provider_id, value} -> {:provider_id, value}
          {key, value} -> {key, integer(value)}
        end)

      Map.put(row, :tokens_per_second, throughput(row.output_tokens, row.duration_ms))
    end)
  end

  # Every totals query names its usage-bearing binding :usage_row so one
  # select works for all of them.
  defp totals(query) do
    query
    |> select([usage_row: row], %{
      input_tokens: summed(row.usage, "input_tokens"),
      output_tokens: summed(row.usage, "output_tokens"),
      cached_input_tokens:
        summed(row.usage, "cached_input_tokens") +
          summed(row.usage, "input_cached_tokens") +
          summed(row.usage, "cache_read_tokens"),
      cache_read_tokens: summed(row.usage, "cache_read_tokens"),
      total_tokens: summed_effective_total(row.usage)
    })
    |> Repo.one()
    |> Map.new(fn {key, value} -> {key, integer(value)} end)
  end

  # A run's issue with a merged pull request is the strongest outcome evidence.
  defp merged_work_query do
    from(run in Execution,
      as: :usage_row,
      join: pull_request in PullRequest,
      on: pull_request.issue_id == run.issue_id,
      where: not is_nil(pull_request.merged_at)
    )
  end

  # Closed without a merged pull request: the issue itself was the outcome.
  defp closed_issues_query do
    from(run in Execution,
      as: :usage_row,
      join: issue in Issue,
      on: issue.id == run.issue_id,
      left_join: pull_request in PullRequest,
      on: pull_request.issue_id == run.issue_id,
      where: issue.state == "closed",
      where: is_nil(pull_request.id) or is_nil(pull_request.merged_at)
    )
  end

  # Succeeded runs carry a digest-verified terminal receipt; count the ones no
  # stronger bucket already counted.
  defp receipt_runs_query do
    from(run in Execution,
      as: :usage_row,
      left_join: issue in Issue,
      on: issue.id == run.issue_id,
      left_join: pull_request in PullRequest,
      on: pull_request.issue_id == run.issue_id,
      where: run.status == "succeeded",
      where: is_nil(issue.id) or issue.state != "closed",
      where: is_nil(pull_request.id) or is_nil(pull_request.merged_at)
    )
  end

  # A completed work job's terminal row must carry its bounded report — that
  # report is the receipt.
  defp completed_jobs_query do
    from(job in Job, as: :usage_row, where: job.status == "completed")
  end

  defp merge_totals(left, right) do
    Map.new(@empty_totals, fn {key, _zero} ->
      {key, Map.fetch!(left, key) + Map.fetch!(right, key)}
    end)
  end

  defp ratio(_numerator, denominator) when denominator in [0, nil], do: nil
  defp ratio(numerator, denominator), do: numerator / denominator

  defp throughput(_output_tokens, duration_ms) when duration_ms <= 0, do: nil
  defp throughput(output_tokens, duration_ms), do: output_tokens / (duration_ms / 1000)

  defp integer(value) when is_integer(value), do: value
  defp integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer(_value), do: 0
end
