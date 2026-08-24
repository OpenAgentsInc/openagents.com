defmodule OpenAgents.DataRights.ExportInventory do
  @moduledoc """
  What a user can take with them, family by family, and what they cannot.

  This is a ledger, not an aspiration. A family is `:portable` only when a
  named proof shows the records coming back to the account that owns them;
  everything else is recorded as reachable-but-unproven, blocked, or not a
  record a user authors, and every gap names the open issue that closes it.
  The classification is deliberately pessimistic: a family stays `:partial`
  until someone writes the proof, because an unproven portability claim is the
  kind of claim this repository does not make.

  The API half of the ledger is derived, not maintained by hand. Every family
  `OpenAgentsWeb.ApiRouteAuthority.families/0` publishes must appear here, so a
  new resource family cannot reach the API without someone deciding whether a
  user can export it. The rest of the ledger names the families that leave
  through routes outside `/api/v3` — Git transport for repository content, the
  data-rights exports for conversations and memory.

  Statuses:

  * `:portable` — a published mechanism returns this family's records to the
    account that owns them, and `proof` names where that is shown.
  * `:partial` — published reads reach the records, but nothing here proves
    that an account gets its own records back, and no account-scoped export
    artifact exists. `issue` names the work.
  * `:blocked` — the account cannot read its own records through any published
    route. Proven, not assumed: every blocked family is probed, so a fix that
    lands without updating this ledger turns the proof red.
  * `:not_user_data` — the family carries no record a user authors and takes
    with them. `note` says why.
  """

  alias OpenAgentsWeb.ApiRouteAuthority

  @typedoc "How a family leaves, or why it cannot."
  @type status :: :portable | :partial | :blocked | :not_user_data

  @typedoc "Where a portability or blockage claim is shown to hold."
  @type proof :: :inventory | {:test, String.t()} | {:invariant, String.t()} | nil

  @typedoc "One family's entry in the ledger."
  @type entry :: %{
          family: atom(),
          api?: boolean(),
          status: status(),
          mechanism: String.t() | nil,
          proof: proof(),
          issue: pos_integer() | nil,
          note: String.t()
        }

  # No account-scoped export of forge-owned and forum-owned data.
  @account_export_issue 143

  @entries [
    # ── proven portable ──────────────────────────────────────────────────
    %{
      family: :issue,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/issues",
      proof: :inventory,
      issue: nil,
      note:
        "Resolves through Repositories.get_visible_by_path!/3, so a member reads " <>
          "a private repository's issues. Paged at 25 by a page number the " <>
          "context clamps at 10,000."
    },
    %{
      family: :project,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/projectsV2",
      proof: :inventory,
      issue: nil,
      note: "Widens for a member the same way issues do; returns the full set unpaged."
    },
    %{
      family: :repository,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v3/user/repos",
      proof: :inventory,
      issue: nil,
      note: "The one account-wide list the API publishes. Cursor paged, so it enumerates."
    },
    %{
      family: :comment,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/issues/{issue_number}/comments",
      proof: :inventory,
      issue: nil,
      note:
        "Resolves through Repositories.get_visible_by_path!/3, so a member reads " <>
          "the comments on a private repository's issues. Returns the full " <>
          "thread on one issue, unpaged."
    },
    %{
      family: :label,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/labels",
      proof: :inventory,
      issue: nil,
      note: "Widens for a member the same way issues do; returns the full set unpaged."
    },
    %{
      family: :milestone,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/milestones",
      proof: :inventory,
      issue: nil,
      note: "Widens for a member, with the open and closed issue counts each milestone carries."
    },
    %{
      family: :assignee,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/assignees",
      proof: :inventory,
      issue: nil,
      note:
        "The accounts a private repository can assign work to, readable by the " <>
          "members it names. Public identity fields only: login, id, avatar."
    },
    %{
      family: :issue_label,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/issues/{issue_number}/labels",
      proof: :inventory,
      issue: nil,
      note: "Widens for a member, one issue at a time."
    },
    %{
      family: :issue_assignee,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/issues/{issue_number}/assignees",
      proof: :inventory,
      issue: nil,
      note: "Widens for a member, one issue at a time."
    },
    %{
      family: :chat,
      api?: true,
      status: :portable,
      mechanism: "GET /data/export",
      proof: {:test, "test/openagents_web/controllers/data_controller_test.exs"},
      issue: nil,
      note:
        "The durable records behind the chat family are conversation messages, " <>
          "turns, and tool steps, which leave through the DATA-004 export rather " <>
          "than through /api/v3."
    },
    %{
      family: :repository_content,
      api?: false,
      status: :portable,
      mechanism: "git clone over the authenticated Git transport",
      proof: {:invariant, "EXIT-004"},
      issue: nil,
      note:
        "An oa_pat_ token with forge:write clones a private repository the " <>
          "account is a member of. The clone is complete and re-serves without " <>
          "the forge."
    },
    %{
      family: :conversation,
      api?: false,
      status: :portable,
      mechanism: "GET /data/export/atif",
      proof: {:test, "test/openagents/data_rights/atif_export_test.exs"},
      issue: nil,
      note: "One bounded ATIF v1.7 trajectory over the account's own conversation."
    },
    %{
      family: :profile_memory,
      api?: false,
      status: :portable,
      mechanism: "GET /memory/export",
      proof: {:test, "test/openagents_web/controllers/data_controller_test.exs"},
      issue: nil,
      note: "Also carried inside the account data export."
    },

    # ── blocked: the owner cannot read their own records ──────────────────
    %{
      family: :push_receipt,
      api?: false,
      status: :blocked,
      mechanism: nil,
      proof: :inventory,
      issue: @account_export_issue,
      note:
        "forge_pushes rows are derived from the WAL and served by no published " <>
          "route. The pusher holds the same facts in their own reflog; the " <>
          "forge's record of them does not leave."
    },

    # ── reachable, not proven portable, no account-scoped export ──────────
    %{
      family: :pull_request,
      api?: true,
      status: :partial,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/pulls",
      proof: nil,
      issue: @account_export_issue,
      note: "Widens for a member, unpaged, scoped to one repository. No proof here yet."
    },
    %{
      family: :stack,
      api?: true,
      status: :partial,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/stacks",
      proof: nil,
      issue: @account_export_issue,
      note: "Widens for a member. Boundary commits live under the unadvertised refs/internal/."
    },
    %{
      family: :issue_dependency,
      api?: true,
      status: :partial,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/issues/{issue_number}/dependencies",
      proof: nil,
      issue: @account_export_issue,
      note: "Widens for a member, one issue at a time."
    },
    %{
      family: :forum,
      api?: true,
      status: :partial,
      mechanism: "GET /api/v3/forum/topics",
      proof: nil,
      issue: @account_export_issue,
      note:
        "Topics and posts read publicly with no author filter, so recovering an " <>
          "account's own posts means walking the whole corpus."
    },
    %{
      family: :deployment,
      api?: true,
      status: :partial,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/deployments",
      proof: nil,
      issue: @account_export_issue,
      note: "Cursor paged per repository, never per account."
    },
    %{
      family: :agent,
      api?: true,
      status: :partial,
      mechanism: "GET /api/v3/agents/links",
      proof: nil,
      issue: @account_export_issue,
      note: "The account's agent links read back; the agent records themselves do not export."
    },
    %{
      family: :box,
      api?: true,
      status: :partial,
      mechanism: "GET /api/v3/conversations/{conversation_id}/boxes",
      proof: nil,
      issue: @account_export_issue,
      note: "Leases and runs read per conversation. No export artifact."
    },
    %{
      family: :computer,
      api?: true,
      status: :partial,
      mechanism: "GET /api/v3/computers",
      proof: nil,
      issue: @account_export_issue,
      note: "The account's paired computers list. No export artifact."
    },
    %{
      family: :thread,
      api?: true,
      status: :partial,
      mechanism: "GET /api/v3/threads/{thread_id}",
      proof: nil,
      issue: @account_export_issue,
      note:
        "A thread reads back only to a caller that already holds its id: there " <>
          "is no route that lists an account's threads, the transcript in " <>
          "thread_events leaves through no route at all, and the DATA-004 " <>
          "export names no thread. Deletion still reaches them through the " <>
          "visitor cascade; the export ledger does not."
    },
    %{
      family: :reputation,
      api?: true,
      status: :partial,
      mechanism: "GET /api/v3/repos/{owner}/{repo}/issues/{issue_number}/attestations",
      proof: nil,
      issue: @account_export_issue,
      note: "Attestations read per issue and per subject, never per account."
    },

    # ── not a record a user authors and takes with them ───────────────────
    %{
      family: :meta,
      api?: true,
      status: :not_user_data,
      mechanism: nil,
      proof: nil,
      issue: nil,
      note: "The API's own route and extension inventory."
    },
    %{
      family: :capacity,
      api?: true,
      status: :not_user_data,
      mechanism: nil,
      proof: nil,
      issue: nil,
      note: "A fleet reading derived from nodes, owned by no account."
    },
    %{
      family: :assignment,
      api?: true,
      status: :not_user_data,
      mechanism: nil,
      proof: nil,
      issue: nil,
      note:
        "A delegation's ref-scoped credential and its lifecycle. The plaintext " <>
          "never persists and the record is the forge's, not the user's."
    },
    %{
      family: :delegation,
      api?: true,
      status: :not_user_data,
      mechanism: nil,
      proof: nil,
      issue: nil,
      note: "A transient control record for one delegated turn."
    },
    %{
      family: :fleet_target,
      api?: true,
      status: :not_user_data,
      mechanism: nil,
      proof: nil,
      issue: nil,
      note:
        "The operator's own append-only record of which commit the fleet runs. " <>
          "It names a promoting operator, not an account's work."
    },
    %{
      family: :device,
      api?: true,
      status: :not_user_data,
      mechanism: nil,
      proof: nil,
      issue: nil,
      note: "A device-authorization grant: a credential lifecycle record, not content."
    }
  ]

  @doc "Every family in the ledger."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "One family's entry, or `nil`."
  @spec entry(atom()) :: entry() | nil
  def entry(family), do: Enum.find(@entries, &(&1.family == family))

  @doc "Families with the given status."
  @spec with_status(status()) :: [entry()]
  def with_status(status), do: Enum.filter(@entries, &(&1.status == status))

  @doc "The families this ledger claims cover the published `/api/v3` surface."
  @spec api_families() :: [atom()]
  def api_families do
    @entries |> Enum.filter(& &1.api?) |> Enum.map(& &1.family) |> Enum.sort()
  end

  @doc """
  Families the API publishes that the ledger does not classify, and families
  the ledger classifies that the API no longer publishes.

  Both directions are errors: the first hides a family from the export
  question, the second leaves a stale claim standing.
  """
  @spec api_family_drift() :: %{unclassified: [atom()], stale: [atom()]}
  def api_family_drift do
    published = MapSet.new(ApiRouteAuthority.families())
    classified = MapSet.new(api_families())

    %{
      unclassified: published |> MapSet.difference(classified) |> Enum.sort(),
      stale: classified |> MapSet.difference(published) |> Enum.sort()
    }
  end
end
