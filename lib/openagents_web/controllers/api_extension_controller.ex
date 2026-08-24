defmodule OpenAgentsWeb.ApiExtensionController do
  @moduledoc """
  The root API description this deployment serves.

  It answers three questions an agent would otherwise answer by reading prose
  or by probing: which OpenAgents-specific fields exist, which routes exist and
  what authority each needs, and what a refusal looks like.

  A field is expected to be read only after it appears in `extensions`, so an
  agent discovers the OpenAgents-specific parts of the API mechanically.
  Responses that carry an extension also name it in the
  `x-openagents-extensions` response header.

  The rules every extension field follows:

  1. It lives under the resource's `openagents` object and never changes a
     GitHub-shaped key.
  2. It is enumerated here before any client is expected to read it, with its
     type and, where it is an enum, the exact values the context derives.
  3. A filter listed here is refused by the endpoint that names it when the
     value falls outside that enum.
  4. A derived field states what it derives from, including whose visibility.

  Rules 1 to 3 are enforced, not merely followed:
  `OpenAgentsWeb.ApiExtensionGovernanceTest` reads this document and the live
  responses and fails on any disagreement between them.

  `routes` is derived from `OpenAgentsWeb.Router.__routes__/0` through
  `OpenAgentsWeb.ApiRouteAuthority`, never hand-maintained beside it, so the
  published inventory cannot drift from what the router serves.
  `OpenAgentsWeb.ApiRouteAuthorityTest` fails when the two disagree, and
  `OpenAgentsWeb.ApiErrorContractTest` fails when a route this document says
  answers with the shared envelope answers with something else.

  `errors` publishes that envelope: its keys, the stable codes, and the one
  status each code carries.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Inference.Credit
  alias OpenAgentsWeb.ApiError
  alias OpenAgentsWeb.ApiRouteAuthority
  alias OpenAgentsWeb.ContributionContract

  @document_version "2026-08-23"

  @issue_reference %{
    "type" => "object",
    "properties" => %{
      "number" => %{"type" => "integer"},
      "title" => %{"type" => "string"},
      "state" => %{"type" => "string", "enum" => ["open", "closed"]}
    }
  }

  @work_attempt %{
    "type" => "object",
    "description" =>
      "One recorded execution attempt against the issue, projected from the " <>
        "durable assignment that bound it. The issue stays the requested " <>
        "outcome; the attempt is never a second work record.",
    "properties" => %{
      "id" => %{"type" => "string"},
      "target" => %{"type" => "string", "enum" => ["box", "computer"]},
      "state" => %{
        "type" => "string",
        "enum" => OpenAgents.Forge.Assignment.states()
      },
      "branch" => %{"type" => "string"},
      "commit" => %{"type" => ["string", "null"]},
      "failure_reason" => %{"type" => ["string", "null"]},
      "started_at" => %{"type" => ["string", "null"]},
      "finished_at" => %{"type" => ["string", "null"]}
    }
  }

  @issue_evidence %{
    "type" => "object",
    "description" =>
      "One receipt bound to the exact commit it evaluated, and to the issue " <>
        "that requested the outcome. The receipt is immutable in the table " <>
        "its family owns; this is the edge, never a copy and never a second " <>
        "work record.",
    "properties" => %{
      "id" => %{"type" => "string"},
      "commit" => %{"type" => "string"},
      "family" => %{
        "type" => "string",
        "enum" => OpenAgents.Issues.EvidenceEntry.families()
      },
      "receipt_id" => %{"type" => "string"},
      "plane" => %{
        "type" => "string",
        "enum" => OpenAgents.Issues.EvidenceEntry.planes(),
        "description" =>
          "Which deployment plane the receipt lives in. An issue in this " <>
            "repository is evidenced by the forge release lane; an issue in a " <>
            "tenant repository is evidenced by the deployment control plane. " <>
            "The two never mix."
      },
      "environment" => %{"type" => ["string", "null"]},
      "result" => %{"type" => ["string", "null"]},
      "source" => %{
        "type" => "string",
        "enum" => OpenAgents.Issues.EvidenceEntry.sources(),
        "description" =>
          "How the commit was resolved to this issue: a closing reference a " <>
            "commit trailer made and a merge confirmed, or an attempt's own " <>
            "report of the revision it produced."
      },
      "recorded_at" => %{"type" => "string"}
    }
  }

  @issue_completion_claim %{
    "type" => "object",
    "description" =>
      "One graded completion claim: what an attempt asserted about the " <>
        "issue's intent at one exact revision, and how the accepted-outcome " <>
        "contract graded it. A receipt says what evaluated a commit; this " <>
        "says what was claimed about the outcome, which is a different " <>
        "question and the only one that can close an issue.",
    "properties" => %{
      "id" => %{"type" => "string"},
      "revision" => %{"type" => "string"},
      "state" => %{
        "type" => "string",
        "enum" => OpenAgents.Issues.CompletionClaim.states(),
        "description" =>
          "The graded verdict. `not_applicable` is human-authored work or a " <>
            "repository that has not enabled agents, which the contract does " <>
            "not gate at all."
      },
      "reasons" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" =>
          "The typed reasons a non-accepted verdict carries, and the reason " <>
            "an accepted claim did not close the issue when it did not."
      },
      "criteria" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "criterion" => %{"type" => "string"},
            "evidence" => %{"type" => ["string", "null"]},
            "visibility" => %{"type" => "string", "enum" => ["public", "private"]}
          }
        },
        "description" =>
          "Which evidence satisfied which acceptance criterion. A criterion " <>
            "satisfied by a private repository's evidence appears as " <>
            "satisfied without the reference."
      },
      "verifier" => %{"type" => ["string", "null"]},
      "falsifier" => %{
        "type" => ["string", "null"],
        "description" =>
          "The observation that would have made this claim red: the same " <>
            "check name, on the same commit and artifact digest, reporting " <>
            "failed."
      },
      "closed" => %{
        "type" => "boolean",
        "description" =>
          "Whether this claim closed the issue. Only a qualification receipt " <>
            "for this exact revision can, only on a repository that opted " <>
            "in, and only when no receipt for that revision failed."
      },
      "closed_at" => %{"type" => ["string", "null"]},
      "closed_by_actor" => %{
        "type" => ["string", "null"],
        "description" =>
          "The system principal an automatic close is attributed to. It is " <>
            "never a user id: a person's close leaves a closing reference " <>
            "with a user behind it instead."
      },
      "contradicted_at" => %{
        "type" => ["string", "null"],
        "description" =>
          "When a later receipt disagreed with the evidence this claim " <>
            "rested on. The issue is never reopened; the claim stops reading " <>
            "as uncontested."
      },
      "contradiction_reason" => %{"type" => ["string", "null"]},
      "recorded_at" => %{"type" => "string"}
    }
  }

  @promise_record %{
    "type" => "object",
    "description" => "A state-gated promise record stored in a project item.",
    "required" => [
      "id",
      "problem",
      "claim",
      "scope",
      "acceptance_criteria",
      "success_metrics",
      "owner",
      "target",
      "evidence"
    ],
    "properties" => %{
      "verified_at" => %{"type" => ["string", "null"]},
      "gate" => %{
        "type" => "object",
        "properties" => %{
          "missing" => %{"type" => "string"},
          "owner" => %{"type" => "string"},
          "next_review" => %{"type" => "string"}
        }
      },
      "withdrawal" => %{
        "type" => "object",
        "properties" => %{
          "reason" => %{"type" => "string"},
          "replacement" => %{"type" => "string"},
          "date" => %{"type" => "string"}
        }
      }
    }
  }

  @extensions %{
    "chat.openagents" => %{
      "version" => "2026-08-23",
      "description" =>
        "The inference backends an account chat turn may choose between. " <>
          "Every backend answers with the same events and the same terminal " <>
          "shape, so the choice changes which model replies and nothing else.",
      "endpoints" => ["POST /api/v3/chat/turns", "GET /api/v3/chat/events"],
      "parameters" => %{
        "model" => %{
          "endpoint" => "POST /api/v3/chat/turns",
          "type" => "string",
          "enum" => OpenAgents.Chat.Backends.ids(),
          "default" => OpenAgents.Chat.Backends.default_id(),
          "description" =>
            "The backend that answers the turn. Omitted or empty selects the " <>
              "default. A value outside this enum is refused with a " <>
              "field-level 422 naming `model`."
        }
      },
      "backends" => OpenAgents.Chat.Backends.catalog()
    },
    "capacity.openagents" => %{
      "version" => "2026-08-23",
      "description" => "Owner-safe quantity-based capacity and matching projections.",
      "endpoints" => [
        "GET /api/capacity",
        "GET /api/v3/capacity",
        "POST /api/v3/capacity/matches"
      ],
      "schemas" => [
        "openagents.capacity.v1",
        "openagents.capacity_match.v1",
        "openagents.capacity_refusal.v1"
      ]
    },
    "issue.openagents" => %{
      "version" => "2026-08-23",
      "description" => "OpenAgents-specific issue fields, namespaced away from the GitHub shape.",
      "fields" => %{
        "blocked" => %{
          "type" => "boolean",
          "description" => "True while any issue in blocked_by is still open."
        },
        "blocked_by" => %{
          "type" => "array",
          "items" => @issue_reference,
          "description" => "Issues that must close before this issue can start."
        },
        "blocks" => %{
          "type" => "array",
          "items" => @issue_reference,
          "description" => "Issues that wait on this issue."
        },
        "progress" => %{
          "type" => "string",
          "enum" => OpenAgents.Issues.progress_values(),
          "description" =>
            "How far along the issue is. Derived: a closed issue is done, and " <>
              "an open issue is in_progress while a board the reader can open " <>
              "places it in a started column."
        },
        "work" => %{
          "type" => "array",
          "items" => @work_attempt,
          "description" =>
            "Every recorded execution attempt against this issue, oldest " <>
              "first, empty when no agent has worked it. Each entry carries " <>
              "only what the attempt already publishes on the issue: target, " <>
              "state, branch, exact commit, and timestamps. Prompts, " <>
              "conversations, reports, and credentials stay out."
        },
        "evidence" => %{
          "type" => "array",
          "items" => @issue_evidence,
          "description" =>
            "Every receipt bound to a commit this issue claims, oldest " <>
              "first, empty when nothing has evaluated one. A failed build, " <>
              "a reverted deployment, and a superseded run all stay: the " <>
              "chain is what happened, not what worked."
        },
        "completion_claims" => %{
          "type" => "array",
          "items" => @issue_completion_claim,
          "description" =>
            "Every completion claim graded against this issue, oldest " <>
              "first. A claim is stored whether or not it was accepted and " <>
              "whether or not it closed anything, so a refusal is on the " <>
              "record rather than silent."
        }
      },
      "filters" => %{
        "blocked" => %{
          "endpoint" => "GET /api/v3/repos/{owner}/{repo}/issues",
          "type" => "boolean",
          "description" => "Lists issues that do or do not have an open prerequisite."
        },
        "progress" => %{
          "endpoint" => "GET /api/v3/repos/{owner}/{repo}/issues",
          "type" => "string",
          "enum" => OpenAgents.Issues.progress_values(),
          "description" =>
            "Lists issues at one derived progress value. It composes with " <>
              "state, so done needs state=all or state=closed."
        },
        "type" => %{
          "endpoint" => "GET /api/v3/repos/{owner}/{repo}/issues",
          "type" => "string",
          "enum" => OpenAgents.Issues.type_values(),
          "default" => "all",
          "description" =>
            "Lists issues, pull requests, or both. A pull request is an issue " <>
              "row here, so the default all matches GitHub, which returns both " <>
              "and marks each pull request with a pull_request object. GitHub " <>
              "has no filter that separates them, so this one is namespaced."
        }
      },
      "endpoints" => [
        "GET /api/v3/repos/{owner}/{repo}/issues/{issue_number}/dependencies",
        "POST /api/v3/repos/{owner}/{repo}/issues/{issue_number}/dependencies",
        "DELETE /api/v3/repos/{owner}/{repo}/issues/{issue_number}/dependencies/{blocked_by_number}"
      ]
    },
    "project_item.openagents" => %{
      "version" => "2026-08-23",
      "description" => "Promise registry fields and append-only item history.",
      "fields" => %{
        "promise" => %{
          "type" => "object",
          "properties" => %{
            "record" => @promise_record,
            "state" => %{"type" => "string", "enum" => ["LIVE", "GATED", "WITHDRAWN"]},
            "verified_at" => %{"type" => ["string", "null"]},
            "bounty_candidate" => %{"type" => "boolean"}
          }
        }
      },
      "filters" => %{
        "promise_state" => %{
          "endpoint" => "GET /api/v3/repos/{owner}/{repo}/projectsV2/{project_number}/items",
          "type" => "string",
          "enum" => ["LIVE", "GATED", "WITHDRAWN"]
        },
        "bounty_candidate" => %{
          "endpoint" => "GET /api/v3/repos/{owner}/{repo}/projectsV2/{project_number}/items",
          "type" => "boolean"
        }
      },
      "endpoints" => [
        "GET /api/v3/repos/{owner}/{repo}/projectsV2/{project_number}/items/{item_id}/events"
      ]
    }
  }

  def show(conn, _params) do
    json(conn, %{
      "api_version" => "v3",
      "version" => @document_version,
      "extensions" => Map.put(@extensions, "thread.openagents", thread_extension()),
      "errors" => errors_contract(),
      "routes" => ApiRouteAuthority.inventory_entries(),
      "families" => Enum.map(ApiRouteAuthority.families(), &Atom.to_string/1),
      "contribution" => contribution(conn)
    })
  end

  # The participation contract is a pointer, not a copy. This document says what
  # the API is; that one says how to take part in the project the API serves, and
  # duplicating either into the other would give a client two answers that can
  # disagree.
  defp contribution(conn) do
    base = conn.assigns[:url_base] || OpenAgentsWeb.Endpoint.url()

    %{
      "contract" => ContributionContract.contract(),
      "version" => ContributionContract.version(),
      "revision" => ContributionContract.revision(),
      "digest" => ContributionContract.digest(base),
      "machine" => base <> "/agents.json",
      "human" => base <> "/agents.md",
      "description" =>
        "How to find work, authenticate, file issues, get a change in, and prove it landed."
    }
  end

  # Built per request, not frozen into a module attribute: the admission cap
  # and the grant ceilings are runtime configuration, and a document that
  # published the value this release was compiled with would be describing a
  # budget no caller is given.
  defp thread_extension do
    %{
      "version" => "2026-08-23",
      "description" =>
        "Threads: the unit of agent work. A thread carries one objective, its " <>
          "transcript, and its own budget, and it holds the model authority a " <>
          "client spends at the inference proxy. It is not the account's " <>
          "conversation, and a grant names one or the other, never both " <>
          "(THREAD-001).",
      "endpoints" => [
        "POST /api/v3/threads",
        "GET /api/v3/threads/{thread_id}",
        "DELETE /api/v3/threads/{thread_id}"
      ],
      "parameters" => %{
        "objective" => %{
          "endpoint" => "POST /api/v3/threads",
          "type" => "string",
          "description" =>
            "What this body of work is for. Required, non-blank, and capped " <>
              "at 32 KB."
        },
        "model" => %{
          "endpoint" => "POST /api/v3/threads",
          "type" => "string",
          "enum" => OpenAgents.Inference.Models.ids(),
          "default" => OpenAgents.Inference.Models.default_id(),
          "description" =>
            "The model the thread's grant pins, and therefore the model every " <>
              "call at the inference proxy reaches. A value outside this enum " <>
              "is refused with a field-level 422 naming `model`. Open a second " <>
              "thread to run other work on another model."
        },
        "reasoning" => %{
          "endpoint" => "POST /api/v3/threads",
          "type" => "string",
          "enum" => OpenAgents.Threads.Thread.reasoning_efforts(),
          "default" => OpenAgents.Threads.default_reasoning(),
          "description" =>
            "The reasoning effort the thread is admitted with. A value " <>
              "outside this enum is refused with a field-level 422 naming " <>
              "`reasoning` rather than replaced by the default."
        },
        "permission_profile" => %{
          "endpoint" => "POST /api/v3/threads",
          "type" => "string",
          "enum" => OpenAgents.Threads.Thread.permission_profiles(),
          "default" => OpenAgents.Threads.default_permission_profile(),
          "description" =>
            "How much of a workspace the thread may change. A value outside " <>
              "this enum is refused with a field-level 422 naming " <>
              "`permission_profile`."
        }
      },
      "limits" => %{
        "maximum_open_threads_per_account" => OpenAgents.Threads.maximum_open_per_account(),
        "grant" => thread_grant_ceilings(),
        "credit" => credit_allowances(),
        "description" =>
          "Admission is capped: an account already holding " <>
            "`maximum_open_threads_per_account` open threads is refused with " <>
            "`thread_quota_reached` until it revokes one. The grant ceilings " <>
            "are the thread's own and are not the delegation ceilings a probe " <>
            "run is minted with. The cost ceiling is not among them: a " <>
            "thread's grant is minted for what the credit under `credit` has " <>
            "left, every thread of one account draws against that same " <>
            "balance, and an account with nothing left is refused " <>
            "`credit_exhausted`. Authority that passes `expires_at` stops " <>
            "being live and stops holding a slot, with or without a request."
      },
      "grant" => %{
        "description" =>
          "POST returns the plaintext token exactly once. Spend it as the " <>
            "bearer at the `url` the response names; the proxy pins the model " <>
            "from the grant, so the model is not a request parameter. GET " <>
            "reports the same grant without the token, with what it has spent " <>
            "against what it was allowed.",
        "fields" => ["token", "url", "model", "expires_at", "limits"],
        "statuses" => OpenAgents.Inference.Grant.statuses()
      },
      "schemas" => ["openagents.thread.event.v1"]
    }
  end

  # The ceilings the context actually mints with, keyed for JSON. Restating the
  # numbers here would let the published budget drift from the one a caller is
  # given, which is the drift this document exists to prevent.
  defp thread_grant_ceilings do
    ceilings = OpenAgents.Threads.ceilings()

    %{
      "max_total_tokens" => ceilings.max_total_tokens,
      "max_calls" => ceilings.max_calls,
      "ttl_seconds" => ceilings.ttl_seconds
    }
  end

  # The two allowances a caller can be minted against. A thread's
  # `max_cost_microusd` is whichever of these applies minus what the account
  # has already spent, so publishing the allowance describes the balance while
  # publishing a per-thread number would describe nothing.
  defp credit_allowances do
    %{
      "account_microusd" => Credit.account_allowance(),
      "visitor_microusd" => Credit.visitor_allowance(),
      "description" =>
        "A signed-in account draws against `account_microusd` and an " <>
          "anonymous visitor against `visitor_microusd`, for the life of the " <>
          "account rather than per thread. A thread's grant is minted for the " <>
          "remainder, so `grant.max_cost_microusd` in the mint response is " <>
          "what is left rather than a fixed cap."
    }
  end

  # One description of one envelope. A client reads the codes it must branch on
  # here rather than collecting them from whatever refusals it happened to hit.
  defp errors_contract do
    %{
      "version" => @document_version,
      "envelope" => ApiError.envelope_keys(),
      "field_errors" =>
        "The `errors` key maps a request field name to an array of messages. " <>
          "It is always present, and it is `{}` when the failure is not field-level.",
      "stable_codes" => ApiError.codes(),
      "applies_to" => "Every route whose `errors` classification in this document is `envelope`.",
      "legacy_keys" => %{
        "error" =>
          "Retained beside the envelope on the participation refusals and the " <>
            "bearer-token refusals that published clients already read. New " <>
            "clients read `code`."
      }
    }
  end
end
