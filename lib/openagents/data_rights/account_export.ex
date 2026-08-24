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
  alias OpenAgents.Machines
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository
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

  defp thread_export(thread, events) do
    %{
      "id" => thread.id,
      "objective" => thread.objective,
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
  defp push_receipts_export(user) do
    principal = account_actor_ref(user)

    receipts =
      Repo.all(
        from receipt in PushReceipt,
          left_join: repository in Repository,
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

  defp deployments_export(user) do
    requests =
      Repo.all(
        from request in Request,
          left_join: repository in Repository,
          on: repository.id == request.repository_id,
          where: request.requested_by_user_id == ^user.id,
          order_by: [asc: request.requested_at, asc: request.id],
          limit: ^(@maximum_deployments + 1),
          select: {request, repository.owner, repository.name}
      )

    approvals =
      Repo.all(
        from approval in Approval,
          left_join: repository in Repository,
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
      "box_run_output_bytes" => @maximum_box_output_bytes
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
        "family" => "pull_request",
        "reason" =>
          "Pull requests, stacks, issue dependencies, and reputation attestations key on a " <>
            "repository rather than on an account, and no cross-repository account-scoped read " <>
            "exists. Enumerating them means walking GET /api/v3/user/repos.",
        "mechanism" => "GET /api/v3/repos/{owner}/{repo}/pulls",
        "issue" => 165
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
