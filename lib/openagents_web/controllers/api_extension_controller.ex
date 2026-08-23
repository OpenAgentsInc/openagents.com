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
      "extensions" => @extensions,
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
