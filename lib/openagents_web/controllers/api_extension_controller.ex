defmodule OpenAgentsWeb.ApiExtensionController do
  @moduledoc """
  The index of OpenAgents extension fields this deployment serves.

  A field is expected to be read only after it appears here, so an agent can
  discover the OpenAgents-specific parts of the API mechanically instead of
  reading prose. Responses that carry an extension also name it in the
  `x-openagents-extensions` response header.
  """

  use OpenAgentsWeb, :controller

  @issue_reference %{
    "type" => "object",
    "properties" => %{
      "number" => %{"type" => "integer"},
      "title" => %{"type" => "string"},
      "state" => %{"type" => "string", "enum" => ["open", "closed"]}
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
        }
      },
      "filters" => %{
        "blocked" => %{
          "endpoint" => "GET /api/v3/repos/{owner}/{repo}/issues",
          "type" => "boolean",
          "description" => "Lists issues that do or do not have an open prerequisite."
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
    json(conn, %{"api_version" => "v3", "extensions" => @extensions})
  end
end
