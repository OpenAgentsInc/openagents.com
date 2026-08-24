defmodule OpenAgents.TokenProductivityTest do
  @moduledoc """
  Productive attribution is exclusive bucketing over durable outcome evidence,
  so the tests that matter are the boundaries: which bucket a run lands in,
  what never counts as productive, and that provider steps stay out of the raw
  totals they would double-count.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.IssuesFixtures

  alias OpenAgents.Accounts
  alias OpenAgents.Context.Composer
  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.ProviderStep
  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Issues
  alias OpenAgents.Providers.Request
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.SCV.DriverAccount
  alias OpenAgents.SCV.Execution
  alias OpenAgents.TokenProductivity
  alias OpenAgents.Work.Job

  test "sums raw volume by source without reading provider steps" do
    user = account("raw-sources")
    conversation = conversation_for(user)

    %{turn: turn, receipt: receipt} = begin_typed_turn(conversation, "Raw volume turn.")

    # The provider step carries its own copy of the same tokens the receipt
    # merges; counting both would double the raw total.
    {:ok, _step} =
      Conversations.record_provider_step_completion(receipt, "response-raw", %{
        "input_tokens" => 100,
        "output_tokens" => 40,
        "total_tokens" => 140
      })

    {:ok, _turn} =
      Conversations.complete_turn(turn, "response-raw", %{
        "input_tokens" => 100,
        "output_tokens" => 40,
        "total_tokens" => 140
      })

    insert_job(conversation, "completed", %{
      "input_tokens" => 30,
      "output_tokens" => 10,
      "total_tokens" => 40
    })

    account = driver_account("raw-sources-driver")

    insert_run(account, 1, "failed", %{
      "input_tokens" => 8,
      "output_tokens" => 2,
      "total_tokens" => 10
    })

    report = TokenProductivity.report()

    assert report.sources.typed_turns.total_tokens == 140
    assert report.sources.work_jobs.total_tokens == 40
    assert report.sources.scv_runs.total_tokens == 10
    assert report.sources.voice_sessions.total_tokens == 0
    assert report.raw.total_tokens == 190
    assert report.raw.input_tokens == 138
    assert report.raw.output_tokens == 52
  end

  test "buckets productive tokens by strongest outcome evidence, each row once" do
    repository = repository_fixture()
    account = driver_account("productive-driver")
    conversation = conversation_for(account("productive-jobs"))

    # Merged work: the job's assignment names an issue with a merged pull
    # request. The assignment is the only record that binds the two.
    merged_issue = issue_fixture(repository, %{title: "merged work"})
    insert_merged_pull_request(repository, merged_issue)

    merged_job =
      insert_job(conversation, "completed", %{
        "input_tokens" => 70,
        "output_tokens" => 30,
        "total_tokens" => 100
      })

    insert_assignment(repository, merged_issue, merged_job)

    # Closed issue: closed without a merged pull request.
    closed_issue = issue_fixture(repository, %{title: "closed issue"})
    {:ok, _closed} = Issues.update_issue(closed_issue, %{"state" => "closed"})

    closed_job =
      insert_job(conversation, "completed", %{
        "input_tokens" => 14,
        "output_tokens" => 6,
        "total_tokens" => 20
      })

    insert_assignment(repository, closed_issue, closed_job)

    # A second assignment against the same merged issue must not count the
    # same job's usage twice.
    insert_assignment(repository, merged_issue, merged_job)

    # Verified receipt: an SCV run that succeeded with its terminal receipt.
    insert_run(account, 3, "succeeded", %{
      "input_tokens" => 7,
      "output_tokens" => 3,
      "total_tokens" => 10
    })

    # A failed run is raw volume only.
    insert_run(account, 4, "failed", %{
      "input_tokens" => 300,
      "output_tokens" => 100,
      "total_tokens" => 400
    })

    # Completed work jobs carry their bounded report; failed ones count as raw
    # volume only.
    insert_job(conversation, "completed", %{"input_tokens" => 4, "output_tokens" => 1})
    insert_job(conversation, "failed", %{"input_tokens" => 900, "output_tokens" => 100})

    report = TokenProductivity.report()

    assert report.productive.merged_work.total_tokens == 100
    assert report.productive.closed_issues.total_tokens == 20
    assert report.productive.verified_receipts.total_tokens == 15
    assert report.productive.total_tokens == 135
    assert report.raw.total_tokens == 1535
    assert_in_delta report.productive.share, 135 / 1535, 0.000001
  end

  test "an unassigned job is a verified receipt, never merged work" do
    repository = repository_fixture()
    conversation = conversation_for(account("unassigned-jobs"))

    issue = issue_fixture(repository, %{title: "merged but unattempted"})
    insert_merged_pull_request(repository, issue)

    insert_job(conversation, "completed", %{
      "input_tokens" => 40,
      "output_tokens" => 10,
      "total_tokens" => 50
    })

    report = TokenProductivity.report()

    assert report.productive.merged_work.total_tokens == 0
    assert report.productive.verified_receipts.total_tokens == 50
  end

  test "cache hit rate spans inclusive and exclusive cached-token spellings" do
    user = account("cache-rate")

    # Typed turns count cached tokens inside input_tokens.
    complete_typed_turn(user, "Cached typed turn.", %{
      "input_tokens" => 80,
      "output_tokens" => 20,
      "total_tokens" => 100,
      "cached_input_tokens" => 60
    })

    # OpenCode-style usage counts cache reads outside input_tokens.
    account = driver_account("cache-rate-driver")

    insert_run(account, 1, "succeeded", %{
      "input_tokens" => 10,
      "output_tokens" => 5,
      "total_tokens" => 15,
      "cache_read_tokens" => 110
    })

    report = TokenProductivity.report()

    assert report.cache.cached_input_tokens == 170
    assert report.cache.input_tokens == 200
    assert_in_delta report.cache.hit_rate, 170 / 200, 0.000001
    assert_in_delta report.split.input_share, 200 / 225, 0.000001
  end

  test "provider throughput reads completed steps grouped by provider" do
    user = account("provider-throughput")
    conversation = conversation_for(user)

    # begin_typed_turn records a "started" step at sequence 1; it must stay
    # invisible to the throughput table.
    %{receipt: receipt} = begin_typed_turn(conversation, "Throughput turn.")

    Repo.insert!(%ProviderStep{
      turn_receipt_id: receipt.id,
      sequence: 2,
      provider_id: "test.provider",
      model_id: "model-v1",
      status: "completed",
      provider_response_id: "response-throughput",
      usage: %{
        "input_tokens" => 980,
        "output_tokens" => 260,
        "total_tokens" => 1240,
        "cached_input_tokens" => 850
      },
      started_at: ~U[2026-08-20 12:00:00.000000Z],
      completed_at: ~U[2026-08-20 12:00:10.000000Z]
    })

    assert [row] = TokenProductivity.providers()
    assert row.provider_id == "test.provider"
    assert row.steps == 1
    assert row.input_tokens == 980
    assert row.output_tokens == 260
    assert row.cached_input_tokens == 850
    assert row.total_tokens == 1240
    assert row.duration_ms == 10_000
    assert_in_delta row.tokens_per_second, 26.0, 0.000001
  end

  test "an empty database reports zeros and no rates" do
    report = TokenProductivity.report()

    assert report.raw.total_tokens == 0
    assert report.productive.total_tokens == 0
    assert report.productive.share == nil
    assert report.cache.hit_rate == nil
    assert report.split.input_share == nil
    assert report.providers == []
  end

  defp account(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()
    suffix = digest |> Base.encode16(case: :lower) |> binary_part(0, 12)

    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: "test-#{suffix}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    user
  end

  defp conversation_for(user) do
    {:ok, conversation} = Conversations.ensure_conversation(user)
    conversation
  end

  defp complete_typed_turn(user, content, usage) do
    conversation = conversation_for(user)
    %{turn: turn} = begin_typed_turn(conversation, content)
    {:ok, _turn} = Conversations.complete_turn(turn, "response-#{turn.id}", usage)
    :ok
  end

  defp begin_typed_turn(conversation, content) do
    {:ok, records} = Conversations.create_turn(conversation, content)
    context = Composer.compose!()
    messages = Conversations.provider_messages(conversation.id)

    request = %Request{
      model_id: "model-v1",
      instructions: context.instructions,
      input: messages
    }

    {:ok, inference} =
      Conversations.begin_inference(records.turn, context, request, "test.provider", [])

    inference
  end

  defp driver_account(label) do
    operator = account("operator-#{label}")

    %DriverAccount{}
    |> DriverAccount.create_changeset(%{
      operator_id: operator.id,
      label: label,
      secret_ref: "file:#{label}-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp insert_run(%DriverAccount{} = account, generation, status, usage) do
    now = DateTime.utc_now()
    report = "Run receipt for generation #{generation}."

    Repo.insert!(%Execution{
      driver_account_id: account.id,
      driver: "codex_app_server",
      principal: "scv:codex_app_server:#{account.id}",
      repository_revision: String.duplicate("a", 40),
      objective: "Bounded test objective.",
      permission_profile: "read_only",
      model: "gpt-5.6-luna",
      reasoning_effort: "low",
      status: status,
      owner_node: "test@node",
      generation: generation,
      lease_expires_at: now,
      report: report,
      report_digest: "sha256:" <> (:crypto.hash(:sha256, report) |> Base.encode16(case: :lower)),
      usage: usage,
      started_at: now,
      completed_at: now
    })
  end

  defp insert_assignment(repository, issue, %Job{} = job) do
    now = DateTime.utc_now()

    Repo.insert!(%Assignment{
      repository_id: repository.id,
      issue_id: issue.id,
      work_job_id: job.id,
      conversation_id: job.conversation_id,
      target_kind: "computer",
      requesting_principal: %{"kind" => "test"},
      branch: "work/#{issue.number}-#{System.unique_integer([:positive])}",
      state: "completed",
      deadline_at: DateTime.add(now, 3600, :second),
      admitted_at: now,
      finished_at: now
    })
  end

  defp insert_job(conversation, status, usage) do
    Repo.insert!(%Job{
      conversation_id: conversation.id,
      owner_visitor_id: conversation.visitor_id,
      surface: "text",
      goal: "Bounded test goal.",
      status: status,
      report: "Terminal report.",
      usage: usage,
      started_at: DateTime.utc_now(),
      completed_at: DateTime.utc_now()
    })
  end

  defp insert_merged_pull_request(repository, issue) do
    Repo.insert!(%PullRequest{
      repository_id: repository.id,
      issue_id: issue.id,
      head_repository_id: repository.id,
      head_ref: "scv/merged-work",
      head_sha: String.duplicate("b", 40),
      base_ref: "main",
      base_sha: String.duplicate("c", 40),
      state: "closed",
      draft: false,
      merged_at: DateTime.utc_now()
    })
  end
end
