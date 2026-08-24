defmodule OpenAgents.DataRights.AccountExport do
  @moduledoc """
  One account-scoped export of the forge-owned and forum-owned records an
  account authored, alongside `sarah.account_data_export.v1` rather than inside
  it.

  `OpenAgents.DataRights.export/3` is scoped to one conversation, because that
  is what Sarah owns. Everything else an account produces here — forum topics
  and posts, threads and their transcripts, push receipts, deployment requests
  and approvals, Box leases and runs, paired computers, agent links — keys on
  the account or on an identity the account has claimed, and before this
  document left through no export at all.

  ## What the account owns

  Two identities resolve to one account and no third does:

  * `user:<account-id>`, the `actor_ref` every topic and post written on this
    surface carries.
  * Every `actor_ref` the account holds a `linked` claim on in
    `forum_actor_links`.

  A migrated post written under a legacy identity nobody has claimed is *not*
  exported, even where a display name makes the authorship obvious. Only a
  `linked` claim resolves a legacy actor to an account
  (`OpenAgents.Forum.actor_user/1`), and an export that guessed wider would
  hand one account another account's writing. The claims themselves travel in
  the document, `pending` and `rejected` included, so an account can see which
  identities it asked for and what the operator decided.

  ## Bounds

  Every collection is capped and reports its own truncation, the way the
  conversation export does. A truncated collection says so in a sibling
  `*_truncated` flag; nothing is dropped silently. Box run output is capped per
  run as well, because a run's output stream has no schema ceiling.

  ## What a recipient can do with it

  The document is one JSON object. Post and topic bodies are the markdown
  source as written, so they re-publish on any surface that renders CommonMark
  without passing back through this forge. Push receipts carry the WAL sequence
  and ref map a `git` clone does not, so they re-attach a history to who pushed
  it and when. Identifiers are this forge's UUIDs, but every cross-reference
  inside the document — a post to its topic, a tip to its post, an event to its
  thread — resolves inside the document itself.

  ## Repository names

  A repository's current owner and name are the repository's, not the
  account's. They travel in this document only where
  `OpenAgents.Repositories.readable_by/2` admits the repository to this
  account, and every collection that renders `owner/name` applies that one
  rule: push receipts, deployment requests, deployment approvals, and the
  four families under `"repository_work"`. A private repository the account
  was removed from, or one renamed after they left, does not tell them what it
  is called now.

  What the rule does to the record differs by family, and the difference is
  stated rather than left to each query. An account-keyed record survives with
  `"repository": null`: a push receipt is the account's own evidence — the WAL
  sequence and ref map a clone does not carry — and withholding it would cost
  the account its own history to protect a name it no longer has. A
  repository-keyed record under `"repository_work"` is withheld entirely,
  because a pull request separated from its repository is not a record the
  account can use.

  ## Repository-keyed work

  Pull requests, stacks, and issue dependencies key on a repository rather than
  on an account, so `"repository_work"` is the one section that reads across
  every repository at once. Enumeration is the easy half. Authorization is the
  hard half, and it is answered by joining
  `OpenAgents.Repositories.readable_by/2` — the predicate every per-repository
  read composes — rather than by a second rule written here. An account that
  authored a pull request in a repository it was later removed from does not
  get that record back, and no widening of the query reaches a private
  repository the account never belonged to.

  What the document does not carry is named in `"not_included"` rather than
  left to inference.
  """

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Agents.{Agent, AgentUserLink}
  alias OpenAgents.Box.{ConversationBox, Run}
  alias OpenAgents.ComputerProjection
  alias OpenAgents.Conversations.{Conversation, Visitor}
  alias OpenAgents.Deployments.{Approval, Request}
  alias OpenAgents.Forge.PushReceipt
  alias OpenAgents.Forum.{ActorLink, Post, TipDestination, TipIntent, TipReceipt, Topic}
  alias OpenAgents.Forum.Forum, as: Board
  alias OpenAgents.Issues.{Issue, IssueDependency}
  alias OpenAgents.Machines
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Membership
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Reputation
  alias OpenAgents.Reputation.Attestation
  alias OpenAgents.Stacks.{Stack, StackEntry}
  alias OpenAgents.Threads.{Event, Thread}

  @schema "openagents.account_export.v1"

  @maximum_forum_topics 2_000
  @maximum_forum_posts 10_000
  @maximum_tips 2_000
  @maximum_threads 1_000
  @maximum_thread_events 10_000
  @maximum_push_receipts 10_000
  @maximum_deployments 2_000
  @maximum_box_runs 2_000
  @maximum_box_output_bytes 65_536
  @maximum_pull_requests 5_000
  @maximum_stacks 2_000
  @maximum_stack_entries 10_000
  @maximum_issue_dependencies 5_000
  @maximum_attestations 5_000

  @doc """
  Builds the account's export document.

  Takes the account and nothing else: the scope is the account, so there is no
  root to disagree with and no argument that could widen it.
  """
  @spec build(User.t()) :: {:ok, map()} | {:error, term()}
  def build(%User{status: "active"} = user) do
    actor_links =
      Repo.all(
        from link in ActorLink, where: link.user_id == ^user.id, order_by: [asc: link.inserted_at]
      )

    refs = authored_actor_refs(user, actor_links)
    visitor_ids = visitor_ids(user)

    {:ok,
     %{
       "schema" => @schema,
       "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
       "scope" => "authenticated_account",
       "account" => %{
         "id" => user.id,
         "github_login" => user.github_login,
         "github_name" => user.github_name
       },
       "identities" => identities_export(user, actor_links, refs),
       "bounds" => bounds(),
       "forum" => forum_export(user, actor_links, refs),
       "threads" => threads_export(visitor_ids),
       "push_receipts" => push_receipts_export(user),
       "deployments" => deployments_export(user),
       "boxes" => boxes_export(visitor_ids),
       "repository_work" => repository_work_export(user),
       "computers" => Enum.map(Machines.list_machines(user.id), &ComputerProjection.project/1),
       "agent_links" => agent_links_export(user),
       "not_included" => not_included()
     }}
  end

  def build(%User{}), do: {:error, :inactive_account}

  @doc "The account's own `actor_ref` on this surface."
  @spec account_actor_ref(User.t()) :: String.t()
  def account_actor_ref(%User{id: id}), do: "user:" <> id

  ## ── identity ───────────────────────────────────────────────────────────

  # Only a `linked` claim resolves a legacy identity, so only a `linked` claim
  # widens what this export reads.
  defp authored_actor_refs(user, actor_links) do
    linked = for link <- actor_links, link.status == "linked", do: link.actor_ref
    Enum.uniq([account_actor_ref(user) | linked])
  end

  defp identities_export(user, actor_links, refs) do
    %{
      "account_actor_ref" => account_actor_ref(user),
      "authored_actor_refs" => refs,
      "claims" => Enum.map(actor_links, &actor_link_export/1),
      "reputation_subject_claims" =>
        user
        |> Reputation.list_subject_claims()
        |> Enum.map(&Reputation.subject_claim_projection/1),
      "resolution_rule" =>
        "A legacy forum identity resolves to this account only through a claim with " <>
          "status \"linked\". Posts under a pending, rejected, or unclaimed actor_ref " <>
          "are not exported here, because nothing has established they are this account's."
    }
  end

  defp actor_link_export(link) do
    %{
      "id" => link.id,
      "actor_ref" => link.actor_ref,
      "status" => link.status,
      "proof_method" => link.proof_method,
      "requested_at" => iso8601(link.inserted_at),
      "linked_at" => iso8601(link.linked_at),
      "rejected_at" => iso8601(link.rejected_at),
      "authored_posts_exported" => link.status == "linked"
    }
  end

  defp visitor_ids(%User{id: user_id}) do
    Repo.all(from visitor in Visitor, where: visitor.user_id == ^user_id, select: visitor.id)
  end

  ## ── forum ──────────────────────────────────────────────────────────────

  defp forum_export(user, actor_links, refs) do
    topics =
      Repo.all(
        from topic in Topic,
          join: board in Board,
          on: board.id == topic.forum_id,
          where: topic.actor_ref in ^refs,
          order_by: [asc: topic.created_at, asc: topic.id],
          limit: ^(@maximum_forum_topics + 1),
          select: {topic, board.slug, board.title}
      )

    posts =
      Repo.all(
        from post in Post,
          join: topic in Topic,
          on: topic.id == post.topic_id,
          join: board in Board,
          on: board.id == topic.forum_id,
          where: post.actor_ref in ^refs,
          order_by: [asc: post.created_at, asc: post.id],
          limit: ^(@maximum_forum_posts + 1),
          select: {post, topic.slug, topic.title, board.slug}
      )

    sent =
      Repo.all(
        from intent in TipIntent,
          where: intent.payer_user_id == ^user.id or intent.payer_actor_ref in ^refs,
          order_by: [asc: intent.inserted_at, asc: intent.id],
          limit: ^(@maximum_tips + 1)
      )

    received =
      Repo.all(
        from intent in TipIntent,
          where: intent.recipient_user_id == ^user.id,
          order_by: [asc: intent.inserted_at, asc: intent.id],
          limit: ^(@maximum_tips + 1)
      )

    destinations =
      Repo.all(
        from destination in TipDestination,
          where: destination.user_id == ^user.id,
          order_by: [asc: destination.inserted_at]
      )

    %{
      "topics" => topics |> Enum.take(@maximum_forum_topics) |> Enum.map(&topic_export/1),
      "topics_truncated" => length(topics) > @maximum_forum_topics,
      "posts" => posts |> Enum.take(@maximum_forum_posts) |> Enum.map(&post_export/1),
      "posts_truncated" => length(posts) > @maximum_forum_posts,
      "claims" => Enum.map(actor_links, &actor_link_export/1),
      "tip_destinations" => Enum.map(destinations, &tip_destination_export/1),
      "tips_sent" => sent |> Enum.take(@maximum_tips) |> tips_export(),
      "tips_sent_truncated" => length(sent) > @maximum_tips,
      "tips_received" => received |> Enum.take(@maximum_tips) |> tips_export(),
      "tips_received_truncated" => length(received) > @maximum_tips
    }
  end

  defp topic_export({topic, board_slug, board_title}) do
    %{
      "id" => topic.id,
      "board_slug" => board_slug,
      "board_title" => board_title,
      "slug" => topic.slug,
      "title" => topic.title,
      "state" => topic.state,
      "pin_state" => topic.pin_state,
      "post_count" => topic.post_count,
      "actor_ref" => topic.actor_ref,
      "actor_display_name" => topic.actor_display_name,
      "tip_sats_total" => topic.tip_sats_total,
      "tip_count" => topic.tip_count,
      "created_at" => iso8601(topic.created_at),
      "archived_at" => iso8601(topic.archived_at)
    }
  end

  defp post_export({post, topic_slug, topic_title, board_slug}) do
    %{
      "id" => post.id,
      "topic_id" => post.topic_id,
      "topic_slug" => topic_slug,
      "topic_title" => topic_title,
      "board_slug" => board_slug,
      "post_number" => post.post_number,
      "body_text" => post.body_text,
      "content_kind" => post.content_kind,
      "actor_ref" => post.actor_ref,
      "actor_display_name" => post.actor_display_name,
      "parent_post_id" => post.parent_post_id,
      "quote_post_id" => post.quote_post_id,
      "state" => post.state,
      "tip_sats_total" => post.tip_sats_total,
      "tip_count" => post.tip_count,
      "created_at" => iso8601(post.created_at),
      "updated_at" => iso8601(post.updated_at),
      "archived_at" => iso8601(post.archived_at)
    }
  end

  # The destination string itself is the account's own address, so it travels;
  # the row carries no key, seed, or node credential to withhold.
  defp tip_destination_export(destination) do
    %{
      "id" => destination.id,
      "kind" => destination.kind,
      "destination" => destination.destination,
      "fingerprint" => destination.fingerprint,
      "label" => destination.label,
      "state" => destination.state,
      "accepting_tips" => destination.accepting_tips,
      "created_at" => iso8601(destination.inserted_at),
      "retired_at" => iso8601(destination.retired_at)
    }
  end

  defp tips_export(intents) do
    ids = Enum.map(intents, & &1.id)

    receipts =
      Repo.all(from receipt in TipReceipt, where: receipt.intent_id in ^ids)
      |> Enum.group_by(& &1.intent_id)

    Enum.map(intents, &tip_export(&1, Map.get(receipts, &1.id, [])))
  end

  defp tip_export(intent, receipts) do
    %{
      "id" => intent.id,
      "post_id" => intent.post_id,
      "topic_id" => intent.topic_id,
      "amount_sats" => intent.amount_sats,
      "counted_sats" => intent.counted_sats,
      "exclusion_reason" => intent.exclusion_reason,
      "state" => intent.state,
      "failure_code" => intent.failure_code,
      "created_at" => iso8601(intent.inserted_at),
      "settled_at" => iso8601(intent.settled_at),
      "failed_at" => iso8601(intent.failed_at),
      "refunded_at" => iso8601(intent.refunded_at),
      "receipts" => Enum.map(receipts, &tip_receipt_export/1)
    }
  end

  defp tip_receipt_export(%TipReceipt{} = receipt) do
    %{
      "id" => receipt.id,
      "kind" => receipt.kind,
      "amount_sats" => receipt.amount_sats,
      "fee_sats" => receipt.fee_sats,
      "payment_hash" => receipt.payment_hash,
      "failure_code" => receipt.failure_code,
      "occurred_at" => iso8601(receipt.occurred_at)
    }
  end

  ## ── threads ────────────────────────────────────────────────────────────

  defp threads_export([]),
    do: %{"records" => [], "records_truncated" => false, "events_truncated" => false}

  defp threads_export(visitor_ids) do
    threads =
      Repo.all(
        from thread in Thread,
          where: thread.owner_visitor_id in ^visitor_ids,
          order_by: [asc: thread.inserted_at, asc: thread.id],
          limit: ^(@maximum_threads + 1)
      )

    kept = Enum.take(threads, @maximum_threads)
    ids = Enum.map(kept, & &1.id)

    events =
      Repo.all(
        from event in Event,
          where: event.thread_id in ^ids,
          order_by: [asc: event.emitted_at, asc: event.id],
          limit: ^(@maximum_thread_events + 1)
      )

    by_thread = events |> Enum.take(@maximum_thread_events) |> Enum.group_by(& &1.thread_id)

    %{
      "records" => Enum.map(kept, &thread_export(&1, Map.get(by_thread, &1.id, []))),
      "records_truncated" => length(threads) > @maximum_threads,
      "events_truncated" => length(events) > @maximum_thread_events
    }
  end

  # The transparency tier travels with the thread. It is the consent record for
  # the transcript beneath it — what the account said may be read, and by whom
  # — so an export that carried the events without it would hand a recipient
  # the data and drop the terms (THREAD-002).
  defp thread_export(thread, events) do
    %{
      "id" => thread.id,
      "objective" => thread.objective,
      "repository" => thread.repository,
      "visibility" => thread.visibility,
      "status" => thread.status,
      "model" => thread.model,
      "reasoning_effort" => thread.reasoning_effort,
      "permission_profile" => thread.permission_profile,
      "generation" => thread.generation,
      "report" => thread.report,
      "report_digest" => thread.report_digest,
      "error_code" => thread.error_code,
      "event_count" => thread.event_count,
      "usage" => thread.usage,
      "started_at" => iso8601(thread.started_at),
      "completed_at" => iso8601(thread.completed_at),
      "events" => Enum.map(events, &thread_event_export/1),
      "events_exported" => length(events)
    }
  end

  defp thread_event_export(event) do
    %{
      "schema" => event.schema,
      "event_type" => event.event_type,
      "payload" => event.payload,
      "emitted_at" => iso8601(event.emitted_at)
    }
  end

  ## ── push receipts ──────────────────────────────────────────────────────

  # `forge_pushes.principal` is `user:<account-id>` for a person's push and an
  # operator or assignment string otherwise, so the account's own pushes are an
  # exact match rather than a guess.
  #
  # The receipt is the account's own and comes back whatever the repository
  # says now. The repository's current owner and name are not, so the join
  # goes through `readable_repositories/1` rather than straight at the table:
  # a receipt for a repository this account can no longer read arrives with
  # `"repository": null` and keeps its `storage_key`, `wal_seq`, and refs.
  defp push_receipts_export(user) do
    principal = account_actor_ref(user)
    readable = readable_repositories(user)

    receipts =
      Repo.all(
        from receipt in PushReceipt,
          left_join: repository in subquery(readable),
          on: repository.storage_key == receipt.repo,
          where: receipt.principal == ^principal,
          order_by: [asc: receipt.inserted_at, asc: receipt.id],
          limit: ^(@maximum_push_receipts + 1),
          select: {receipt, repository.name, repository.owner}
      )

    %{
      "records" =>
        receipts |> Enum.take(@maximum_push_receipts) |> Enum.map(&push_receipt_export/1),
      "records_truncated" => length(receipts) > @maximum_push_receipts
    }
  end

  defp push_receipt_export({receipt, name, owner_login}) do
    %{
      "id" => receipt.id,
      "storage_key" => receipt.repo,
      "repository" => repository_path(owner_login, name),
      "wal_seq" => receipt.wal_seq,
      "principal" => receipt.principal,
      "refs" => receipt.refs,
      "duration_ms" => receipt.duration_ms,
      "pushed_at" => iso8601(receipt.inserted_at)
    }
  end

  defp repository_path(nil, _name), do: nil
  defp repository_path(_owner, nil), do: nil
  defp repository_path(owner, name), do: owner <> "/" <> name

  ## ── deployments ────────────────────────────────────────────────────────

  # Both reads are keyed on the account — the requester of a deployment and the
  # approver of one — so both records survive a lost membership. Both join
  # `readable_repositories/1` for the same reason the push receipts do: the
  # request is the account's, the repository's current name is not.
  defp deployments_export(user) do
    readable = readable_repositories(user)

    requests =
      Repo.all(
        from request in Request,
          left_join: repository in subquery(readable),
          on: repository.id == request.repository_id,
          where: request.requested_by_user_id == ^user.id,
          order_by: [asc: request.requested_at, asc: request.id],
          limit: ^(@maximum_deployments + 1),
          select: {request, repository.owner, repository.name}
      )

    approvals =
      Repo.all(
        from approval in Approval,
          left_join: repository in subquery(readable),
          on: repository.id == approval.repository_id,
          where: approval.approver_user_id == ^user.id,
          order_by: [asc: approval.decided_at, asc: approval.id],
          limit: ^(@maximum_deployments + 1),
          select: {approval, repository.owner, repository.name}
      )

    %{
      "requests" =>
        requests |> Enum.take(@maximum_deployments) |> Enum.map(&deployment_request_export/1),
      "requests_truncated" => length(requests) > @maximum_deployments,
      "approvals" =>
        approvals |> Enum.take(@maximum_deployments) |> Enum.map(&deployment_approval_export/1),
      "approvals_truncated" => length(approvals) > @maximum_deployments
    }
  end

  defp deployment_request_export({request, owner_login, name}) do
    %{
      "id" => request.id,
      "repository" => repository_path(owner_login, name),
      "environment_id" => request.environment_id,
      "commit_sha" => request.commit_sha,
      "artifact_digest" => request.artifact_digest,
      "source_ref" => request.source_ref,
      "source_workflow" => request.source_workflow,
      "principal_type" => request.principal_type,
      "request_digest" => request.request_digest,
      "requested_at" => iso8601(request.requested_at)
    }
  end

  defp deployment_approval_export({approval, owner_login, name}) do
    %{
      "id" => approval.id,
      "repository" => repository_path(owner_login, name),
      "deployment_run_id" => approval.deployment_run_id,
      "decision" => approval.decision,
      "rule" => approval.rule,
      "comment" => approval.comment,
      "request_digest" => approval.request_digest,
      "decided_at" => iso8601(approval.decided_at)
    }
  end

  ## ── boxes ──────────────────────────────────────────────────────────────

  defp boxes_export([]), do: %{"leases" => [], "runs" => [], "runs_truncated" => false}

  defp boxes_export(visitor_ids) do
    conversation_ids =
      Repo.all(
        from conversation in Conversation,
          where: conversation.visitor_id in ^visitor_ids,
          select: conversation.id
      )

    leases =
      Repo.all(
        from box in ConversationBox,
          where: box.conversation_id in ^conversation_ids,
          order_by: [asc: box.inserted_at]
      )

    runs =
      Repo.all(
        from run in Run,
          where: run.conversation_id in ^conversation_ids,
          order_by: [asc: run.inserted_at, asc: run.id],
          limit: ^(@maximum_box_runs + 1)
      )

    %{
      "leases" => Enum.map(leases, &box_lease_export/1),
      "runs" => runs |> Enum.take(@maximum_box_runs) |> Enum.map(&box_run_export/1),
      "runs_truncated" => length(runs) > @maximum_box_runs
    }
  end

  defp box_lease_export(box) do
    %{
      "id" => box.id,
      "box_id" => box.box_id,
      "label" => box.label,
      "state" => box.state,
      "setup_status" => box.setup_status,
      "lifetime_seconds" => box.lifetime_seconds,
      "settled_cost_microusd" => box.settled_cost_microusd,
      "created_at" => iso8601(box.inserted_at),
      "stopped_at" => iso8601(box.stopped_at),
      "stop_reason" => box.stop_reason
    }
  end

  # A run's output is a stream with no schema ceiling, so it is capped here and
  # the cap is reported per run rather than applied silently.
  defp box_run_export(run) do
    output = run.output || ""
    kept = binary_part(output, 0, min(byte_size(output), @maximum_box_output_bytes))

    %{
      "id" => run.id,
      "conversation_box_id" => run.conversation_box_id,
      "command" => run.command,
      "state" => run.state,
      "exit_status" => run.exit_status,
      "timed_out" => run.timed_out,
      "output" => kept,
      "output_truncated" => byte_size(output) > @maximum_box_output_bytes,
      "output_byte_size" => byte_size(output),
      "failure_reason" => run.failure_reason,
      "admitted_at" => iso8601(run.admitted_at),
      "started_at" => iso8601(run.started_at),
      "finished_at" => iso8601(run.finished_at)
    }
  end

  ## ── repository-keyed work ──────────────────────────────────────────────

  # Pull requests, stacks, and issue dependencies key on a repository rather
  # than on an account, so reading them per account is a wider query than any
  # other read on this surface. Authorization is the whole problem: the
  # authoring column alone would return a record from a repository the account
  # was removed from, and a repository-shaped query written from memory would
  # reach a private repository the account never belonged to. Every query here
  # joins `OpenAgents.Repositories.readable_by/2` — the one predicate every
  # repository surface composes — so the widened read cannot be looser than the
  # per-repository reads it replaces.
  defp repository_work_export(user) do
    readable = readable_repositories(user)

    %{
      "authorization" =>
        "Every record here passes OpenAgents.Repositories.readable_by/2, the predicate the " <>
          "per-repository API reads compose. A record the account authored in a repository it " <>
          "can no longer read is not returned, and no record from a repository the account is " <>
          "not a member of reaches this document.",
      "pull_requests" => pull_requests_export(user, readable),
      "stacks" => stacks_export(user, readable),
      "issue_dependencies" => issue_dependencies_export(user, readable),
      "attestations" => attestations_export(user, readable)
    }
  end

  # A reputation attestation names its subject with a bare string, so the
  # filter is the subject binding rather than an authoring column: the strings
  # this account has a `linked` claim on in `reputation_subject_claims`. An
  # account with no linked claim gets nothing, and a subject another account
  # holds is unreachable, because the table's unique index on `subject_id`
  # means one string resolves to at most one account.
  #
  # Disclosure does not widen here. `readable_by/2` admits a public repository
  # to a non-member, and `OpenAgentsWeb.ReputationController` shows such a
  # reader `public` attestations only, so the same membership test gates the
  # `repository` and `private` tiers in this document. The account is active —
  # `build/1` refuses an inactive one — so a membership row is the whole of
  # `Repositories.member?/2` here.
  defp attestations_export(user, readable) do
    subject_ids = Reputation.linked_subject_ids(user)

    rows =
      Repo.all(
        from attestation in Attestation,
          join: repository in subquery(readable),
          on: repository.id == attestation.repository_id,
          left_join: membership in Membership,
          on: membership.repository_id == repository.id and membership.user_id == ^user.id,
          where:
            attestation.subject_id in ^subject_ids and
              (attestation.transparency_tier == "public" or not is_nil(membership.user_id)),
          order_by: [asc: attestation.attested_at, asc: attestation.id],
          limit: ^(@maximum_attestations + 1),
          select: {attestation, repository.owner, repository.name}
      )

    %{
      "subject_resolution_rule" =>
        "An attestation reaches this document only through a reputation subject claim with " <>
          "status \"linked\". The issuer supplies a bare subject_id, so nothing but an " <>
          "established claim says the subject is this account's, and one subject string " <>
          "resolves to at most one account.",
      "established_subjects" => subject_ids,
      "records" => rows |> Enum.take(@maximum_attestations) |> Enum.map(&attestation_export/1),
      "records_truncated" => length(rows) > @maximum_attestations
    }
  end

  # The signed claim travels verbatim beside its signature and the issuer key,
  # so a recipient checks the attestation offline the way
  # `OpenAgentsWeb.ReputationController` lets a stranger check it.
  defp attestation_export({attestation, owner_login, name}) do
    %{
      "id" => attestation.id,
      "repository" => repository_path(owner_login, name),
      "issue_number" => attestation.issue_number,
      "event_type" => attestation.event_type,
      "subject_id" => attestation.subject_id,
      "issuer_key_id" => attestation.issuer_key_id,
      "transparency_tier" => attestation.transparency_tier,
      "claim" => attestation.claim,
      "claim_digest" => attestation.claim_digest,
      "signature" => attestation.signature,
      "signature_algorithm" => attestation.signature_algorithm,
      "revoked" => not is_nil(attestation.revoked_at),
      "revocation_reason_code" => attestation.revocation_reason_code,
      "attested_at" => iso8601(attestation.attested_at)
    }
  end

  # A repository's identity comes back with the predicate rather than beside
  # it, so a caller cannot name a repository this query did not admit. Every
  # collection that renders `owner/name` joins this one query — the four
  # repository-keyed families here, and the account-keyed push receipts and
  # deployments above — so the module cannot state one disclosure rule and
  # apply two. `storage_key` rides along because a push receipt names its
  # repository by that key rather than by `repository_id`.
  defp readable_repositories(user) do
    from repository in Repositories.readable_by(Repository, user),
      select: %{
        id: repository.id,
        owner: repository.owner,
        name: repository.name,
        storage_key: repository.storage_key
      }
  end

  defp pull_requests_export(user, readable) do
    rows =
      Repo.all(
        from pull_request in PullRequest,
          join: repository in subquery(readable),
          on: repository.id == pull_request.repository_id,
          join: issue in Issue,
          on: issue.id == pull_request.issue_id,
          left_join: head in subquery(readable),
          on: head.id == pull_request.head_repository_id,
          where:
            pull_request.opened_by_user_id == ^user.id or
              pull_request.merged_by_user_id == ^user.id,
          order_by: [asc: pull_request.inserted_at, asc: pull_request.id],
          limit: ^(@maximum_pull_requests + 1),
          select:
            {pull_request, repository.owner, repository.name, issue.number, issue.title,
             head.owner, head.name}
      )

    %{
      "records" =>
        rows |> Enum.take(@maximum_pull_requests) |> Enum.map(&pull_request_export(&1, user)),
      "records_truncated" => length(rows) > @maximum_pull_requests
    }
  end

  defp pull_request_export(row, user) do
    {pull_request, owner_login, name, number, title, head_owner, head_name} = row

    %{
      "id" => pull_request.id,
      "repository" => repository_path(owner_login, name),
      "number" => number,
      "title" => title,
      "state" => pull_request.state,
      "draft" => pull_request.draft,
      "head_ref" => pull_request.head_ref,
      "head_sha" => pull_request.head_sha,
      "head_repository" => repository_path(head_owner, head_name),
      "base_ref" => pull_request.base_ref,
      "base_sha" => pull_request.base_sha,
      "opened_by_account" => pull_request.opened_by_user_id == user.id,
      "merged_by_account" => pull_request.merged_by_user_id == user.id,
      "merge_commit_sha" => pull_request.merge_commit_sha,
      "opened_at" => iso8601(pull_request.inserted_at),
      "merged_at" => iso8601(pull_request.merged_at)
    }
  end

  # A stack's boundary commits live under `refs/internal/`, which
  # `EXIT-004` records as the one namespace a clone does not advertise. The
  # object ids travel here, so the account keeps the shape of its own stack
  # even though the refs holding it are not fetchable.
  defp stacks_export(user, readable) do
    rows =
      Repo.all(
        from stack in Stack,
          join: repository in subquery(readable),
          on: repository.id == stack.repository_id,
          where: stack.created_by_user_id == ^user.id,
          order_by: [asc: stack.inserted_at, asc: stack.id],
          limit: ^(@maximum_stacks + 1),
          select: {stack, repository.owner, repository.name}
      )

    kept = Enum.take(rows, @maximum_stacks)
    stack_ids = Enum.map(kept, fn {stack, _owner, _name} -> stack.id end)
    entries = stack_entries(stack_ids)
    by_stack = entries |> Enum.take(@maximum_stack_entries) |> Enum.group_by(&elem(&1, 1))

    %{
      "records" =>
        Enum.map(kept, fn {stack, owner_login, name} ->
          stack_export(stack, owner_login, name, Map.get(by_stack, stack.id, []))
        end),
      "records_truncated" => length(rows) > @maximum_stacks,
      "entries_truncated" => length(entries) > @maximum_stack_entries
    }
  end

  defp stack_entries([]), do: []

  defp stack_entries(stack_ids) do
    Repo.all(
      from entry in StackEntry,
        join: pull_request in PullRequest,
        on: pull_request.id == entry.pull_request_id,
        join: issue in Issue,
        on: issue.id == pull_request.issue_id,
        where: entry.stack_id in ^stack_ids,
        order_by: [asc: entry.stack_id, asc: entry.position, asc: entry.id],
        limit: ^(@maximum_stack_entries + 1),
        select: {entry, entry.stack_id, issue.number, pull_request.head_ref}
    )
  end

  defp stack_export(stack, owner_login, name, entries) do
    %{
      "id" => stack.id,
      "repository" => repository_path(owner_login, name),
      "number" => stack.number,
      "trunk_ref" => stack.trunk_ref,
      "state" => stack.state,
      "health" => stack.health,
      "version" => stack.version,
      "created_at" => iso8601(stack.inserted_at),
      "entries" => Enum.map(entries, &stack_entry_export/1),
      "entries_exported" => length(entries)
    }
  end

  defp stack_entry_export({entry, _stack_id, number, head_ref}) do
    %{
      "position" => entry.position,
      "pull_request_number" => number,
      "head_ref" => head_ref,
      "boundary_oid" => entry.boundary_oid,
      "observed_head_oid" => entry.observed_head_oid,
      "removed_at" => iso8601(entry.removed_at)
    }
  end

  defp issue_dependencies_export(user, readable) do
    rows =
      Repo.all(
        from dependency in IssueDependency,
          join: repository in subquery(readable),
          on: repository.id == dependency.repository_id,
          join: issue in Issue,
          on: issue.id == dependency.issue_id,
          join: blocker in Issue,
          on: blocker.id == dependency.blocked_by_issue_id,
          where: dependency.created_by_user_id == ^user.id,
          order_by: [asc: dependency.inserted_at, asc: dependency.id],
          limit: ^(@maximum_issue_dependencies + 1),
          select:
            {dependency, repository.owner, repository.name, issue.number, issue.title,
             blocker.number, blocker.title, blocker.state}
      )

    %{
      "records" =>
        rows |> Enum.take(@maximum_issue_dependencies) |> Enum.map(&issue_dependency_export/1),
      "records_truncated" => length(rows) > @maximum_issue_dependencies
    }
  end

  defp issue_dependency_export(row) do
    {dependency, owner_login, name, number, title, blocker_number, blocker_title, blocker_state} =
      row

    %{
      "id" => dependency.id,
      "repository" => repository_path(owner_login, name),
      "issue_number" => number,
      "issue_title" => title,
      "blocked_by_issue_number" => blocker_number,
      "blocked_by_issue_title" => blocker_title,
      "blocked_by_issue_state" => blocker_state,
      "recorded_at" => iso8601(dependency.inserted_at)
    }
  end

  ## ── agents ─────────────────────────────────────────────────────────────

  defp agent_links_export(%User{id: user_id}) do
    Repo.all(
      from link in AgentUserLink,
        join: agent in Agent,
        on: agent.id == link.agent_id,
        where: link.user_id == ^user_id,
        order_by: [asc: link.inserted_at],
        select: {link, agent}
    )
    |> Enum.map(fn {link, agent} ->
      %{
        "id" => link.id,
        "status" => link.status,
        "proof_method" => link.proof_method,
        "requested_at" => iso8601(link.inserted_at),
        "linked_at" => iso8601(link.linked_at),
        "rejected_at" => iso8601(link.rejected_at),
        "agent" => %{
          "id" => agent.id,
          "handle" => agent.handle,
          "display_name" => agent.display_name,
          "status" => agent.status
        }
      }
    end)
  end

  ## ── bounds and gaps ────────────────────────────────────────────────────

  defp bounds do
    %{
      "forum_topics" => @maximum_forum_topics,
      "forum_posts" => @maximum_forum_posts,
      "forum_tips" => @maximum_tips,
      "threads" => @maximum_threads,
      "thread_events" => @maximum_thread_events,
      "push_receipts" => @maximum_push_receipts,
      "deployments" => @maximum_deployments,
      "box_runs" => @maximum_box_runs,
      "box_run_output_bytes" => @maximum_box_output_bytes,
      "pull_requests" => @maximum_pull_requests,
      "stacks" => @maximum_stacks,
      "stack_entries" => @maximum_stack_entries,
      "issue_dependencies" => @maximum_issue_dependencies,
      "attestations" => @maximum_attestations
    }
  end

  # Stated in the document, not only in the ledger: a recipient reading this
  # file offline should not have to infer what is missing.
  defp not_included do
    [
      %{
        "family" => "conversation",
        "reason" => "Sarah's conversation, memory, voice, and tool steps export separately.",
        "mechanism" => "GET /data/export and GET /data/export/atif",
        "issue" => nil
      },
      %{
        "family" => "repository_content",
        "reason" =>
          "Git history leaves through the authenticated Git transport, not this document.",
        "mechanism" => "git clone with an oa_pat_ token",
        "issue" => nil
      },
      %{
        "family" => "repository_identity",
        "reason" =>
          "A repository's current owner and name appear only where the account can still read " <>
            "the repository. A push receipt, deployment request, or approval for a repository " <>
            "the account was removed from arrives with a null repository and keeps every field " <>
            "that is the account's own; a record under repository_work is withheld instead, " <>
            "because it has no meaning apart from its repository.",
        "mechanism" => "OpenAgents.Repositories.readable_by/2",
        "issue" => nil
      },
      %{
        "family" => "forum",
        "reason" =>
          "Posts written under a legacy actor_ref this account has not claimed, or whose claim " <>
            "is still pending, are not exported. Only a linked claim resolves a legacy identity.",
        "mechanism" => "POST /api/v3/forum/claims",
        "issue" => nil
      }
    ]
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp iso8601(%NaiveDateTime{} = timestamp), do: NaiveDateTime.to_iso8601(timestamp)
end
