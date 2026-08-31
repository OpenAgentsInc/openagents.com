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
  through routes outside `/api/v1` — Git transport for repository content, the
  data-rights exports for conversations and memory, and `GET
  /data/export/account` for the forge-owned and forum-owned records an account
  authors.

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

  # The account-scoped export of forge-owned and forum-owned records, #143.
  @account_export "GET /data/export/account"
  @account_export_proof {:test, "test/openagents/data_rights/account_export_test.exs"}

  @entries [
    # ── proven portable ──────────────────────────────────────────────────
    %{
      family: :issue,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v1/repos/{owner}/{repo}/issues",
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
      mechanism: "GET /api/v1/repos/{owner}/{repo}/projectsV2",
      proof: :inventory,
      issue: nil,
      note: "Widens for a member the same way issues do; returns the full set unpaged."
    },
    %{
      family: :repository,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v1/user/repos",
      proof: :inventory,
      issue: nil,
      note: "The one account-wide list the API publishes. Cursor paged, so it enumerates."
    },
    %{
      family: :comment,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v1/repos/{owner}/{repo}/issues/{issue_number}/comments",
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
      mechanism: "GET /api/v1/repos/{owner}/{repo}/labels",
      proof: :inventory,
      issue: nil,
      note: "Widens for a member the same way issues do; returns the full set unpaged."
    },
    %{
      family: :milestone,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v1/repos/{owner}/{repo}/milestones",
      proof: :inventory,
      issue: nil,
      note: "Widens for a member, with the open and closed issue counts each milestone carries."
    },
    %{
      family: :assignee,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v1/repos/{owner}/{repo}/assignees",
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
      mechanism: "GET /api/v1/repos/{owner}/{repo}/issues/{issue_number}/labels",
      proof: :inventory,
      issue: nil,
      note: "Widens for a member, one issue at a time."
    },
    %{
      family: :issue_assignee,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v1/repos/{owner}/{repo}/issues/{issue_number}/assignees",
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
          "turns, tool steps, and the account chat backend's own runs and event " <>
          "stream, all of which leave through the DATA-004 export rather than " <>
          "through /api/v1."
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
    %{
      family: :push_receipt,
      api?: true,
      status: :portable,
      mechanism: @account_export,
      proof: @account_export_proof,
      issue: nil,
      note:
        "forge_pushes.principal is user:<account-id> for a person's push, so " <>
          "the account export returns exactly the account's own rows with the " <>
          "WAL sequence and ref map a clone does not carry. A repository-scoped " <>
          "read is published too, GET /api/v1/repos/{owner}/{repo}/pushes, " <>
          "proven by " <>
          "test/openagents_web/controllers/push_receipt_controller_test.exs. It " <>
          "serves the WAL's own entries rather than the derived rows, so it " <>
          "carries the EXIT-005 chain link git push printed to the pusher."
    },
    %{
      family: :forum,
      api?: true,
      status: :portable,
      mechanism: @account_export,
      proof: @account_export_proof,
      issue: nil,
      note:
        "The public reads still take no author filter; the account export " <>
          "returns the topics, posts, claims, tip destinations, and tips that " <>
          "belong to user:<account-id> and to every actor_ref the account holds " <>
          "a linked claim on. A migrated post under an unclaimed or still-pending " <>
          "legacy identity is deliberately not exported: only a linked claim " <>
          "establishes whose it is."
    },
    %{
      family: :deployment,
      api?: true,
      status: :portable,
      mechanism: @account_export,
      proof: @account_export_proof,
      issue: nil,
      note:
        "The API read stays operator-scoped and per repository. What an account " <>
          "authored is its deployment requests and its approval decisions, keyed " <>
          "by requested_by_user_id and approver_user_id, and those export. Runs, " <>
          "events, and node results are the operator's record of the fleet."
    },
    %{
      family: :agent,
      api?: true,
      status: :portable,
      mechanism: @account_export,
      proof: @account_export_proof,
      issue: nil,
      note:
        "An agent is not owned by one account, so what exports is the account's " <>
          "own links — every status, not only linked — with the handle, display " <>
          "name, and status of the agent each one names."
    },
    %{
      family: :box,
      api?: true,
      status: :portable,
      mechanism: @account_export,
      proof: @account_export_proof,
      issue: nil,
      note:
        "Leases and runs key on a conversation, whose visitor keys on the " <>
          "account, so both export. Run output has no schema ceiling and is " <>
          "capped per run at 64 KB with the cap reported alongside the full " <>
          "byte size, rather than truncated silently."
    },
    %{
      family: :computer,
      api?: true,
      status: :portable,
      mechanism: @account_export,
      proof: @account_export_proof,
      issue: nil,
      note:
        "The same ComputerProjection the account-scoped API list renders, " <>
          "carried into the export document so it leaves with everything else."
    },
    %{
      family: :thread,
      api?: true,
      status: :portable,
      mechanism: @account_export,
      proof: @account_export_proof,
      issue: nil,
      note:
        "Still no route lists an account's threads and none serves thread_events. " <>
          "The account export joins threads through their owner visitor and " <>
          "carries the objective, the terminal report, usage, and the transcript, " <>
          "so the export ledger now reaches what the deletion cascade always did."
    },
    %{
      family: :credit,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v1/credit",
      proof: {:test, "test/openagents_web/controllers/credit_controller_test.exs"},
      issue: nil,
      note:
        "The account's own inference money: what it was granted, what its " <>
          "grants metered, what is left, and how much of that spend carries no " <>
          "price. One read, scoped to the caller, so the account gets the whole " <>
          "record rather than a projection of it. The grants the spend is summed " <>
          "from leave with the threads that hold them."
    },
    %{
      family: :memory,
      api?: true,
      status: :portable,
      mechanism: "GET /api/v1/memories",
      proof: {:test, "test/openagents_web/controllers/memory_controller_test.exs"},
      issue: nil,
      note:
        "The list route is the export: it returns every memory the account " <>
          "wrote, live and superseded both, to that account and to nobody " <>
          "else. Unlike the recall planes this store is authoritative — the " <>
          "sentence a reader typed once is the only copy — so it leaves " <>
          "through a route of its own rather than as a projection of messages."
    },
    %{
      family: :pull_request,
      api?: true,
      status: :portable,
      mechanism: @account_export,
      proof: @account_export_proof,
      issue: nil,
      note:
        "A pull request keys on a repository, so the account export reads across " <>
          "every repository at once and gates the read on " <>
          "Repositories.readable_by/2 rather than on the authoring column alone. " <>
          "Returned for the account that opened it and for the account that " <>
          "merged it, each said in the record."
    },
    %{
      family: :stack,
      api?: true,
      status: :portable,
      mechanism: @account_export,
      proof: @account_export_proof,
      issue: nil,
      note:
        "The stacks the account created, with their entries in order. Boundary " <>
          "commits live under the unadvertised refs/internal/ that EXIT-004 names, " <>
          "so the object ids travel in the document even though a clone cannot " <>
          "fetch the refs holding them."
    },
    %{
      family: :issue_dependency,
      api?: true,
      status: :portable,
      mechanism: @account_export,
      proof: @account_export_proof,
      issue: nil,
      note:
        "The prerequisite edges the account recorded, with both issue numbers and " <>
          "the prerequisite's own state, behind the same readable_by gate."
    },
    %{
      family: :reputation,
      api?: true,
      status: :portable,
      mechanism: @account_export,
      proof: @account_export_proof,
      issue: nil,
      note:
        "An attestation names its subject with a bare string the issuer supplies, " <>
          "so the filter is a binding rather than an authoring column: the " <>
          "subject strings the account holds a linked claim on in " <>
          "reputation_subject_claims, #171. The table's unique index on " <>
          "subject_id means one string resolves to at most one account. The " <>
          "records travel under repository_work behind the same readable_by " <>
          "gate, and the repository and private tiers stay behind the membership " <>
          "test OpenAgentsWeb.ReputationController applies."
    },

    # ── a record a user authors that nothing gives back ───────────────────
    %{
      family: :trace,
      api?: true,
      status: :blocked,
      # There is none. `POST /api/v1/traces` is the whole surface: a person
      # uploads their own agent transcript and no route reads one back, not
      # their own and not by id. That is a record they authored, held on their
      # behalf, with no way to take it with them.
      mechanism: nil,
      proof: :inventory,
      # #217 owns this surface — it is the issue the upload route was built
      # under — and the missing read is part of it. Named rather than opening a
      # second issue for half of one surface.
      issue: 217,
      note:
        "Write-only. `POST /api/v1/traces` accepts an ATIF trace and nothing " <>
          "reads one back, not by id and not for the owner, so an uploaded " <>
          "trace cannot be exported. Classified when the route landed rather " <>
          "than left undeclared, because an unclassified family is one the " <>
          "export question never reaches."
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
      family: :coder_identity,
      api?: true,
      status: :not_user_data,
      mechanism: nil,
      proof: nil,
      issue: nil,
      note:
        "A short-lived identity and repository projection for Coder. It reads " <>
          "the account's retained GitHub connection but does not create or " <>
          "return a user-authored OpenAgents record."
    },
    %{
      family: :model,
      api?: true,
      status: :not_user_data,
      mechanism: nil,
      proof: nil,
      issue: nil,
      note:
        "The typed model catalog a thread is admitted against. It is the " <>
          "deployment's configuration — which models are served and at what " <>
          "ceilings — and carries no record an account authors. What an " <>
          "account did with a model is its threads, which export whole."
    },
    %{
      family: :response,
      api?: true,
      status: :not_user_data,
      mechanism: nil,
      proof: nil,
      issue: nil,
      note:
        "The OpenResponses surface. It answers a request and records " <>
          "nothing — no model is consulted, no row is written — so there is " <>
          "no record for an account to take away. This classification is " <>
          "true of the stub and must be revisited the day a real loop " <>
          "stands behind the route and starts recording what it was asked."
    },
    %{
      family: :gym,
      api?: true,
      status: :not_user_data,
      mechanism: nil,
      proof: nil,
      issue: nil,
      note:
        "Operator benchmark rows: graded runs of our own agents against " <>
          "task suites, posted by the bench harness. Aggregate measurement " <>
          "of the product, carrying no record an account authors."
    },
    %{
      family: :plugin,
      api?: true,
      status: :not_user_data,
      mechanism: nil,
      proof: nil,
      issue: nil,
      note:
        "The plugin registry index: validated manifests discovered from forge " <>
          "repositories, each naming an artifact by digest. A manifest is a " <>
          "published description of code, not a record an account authors — " <>
          "what a person did with a plugin is their thread events, which " <>
          "export whole."
    },
    %{
      family: :issue_activity,
      api?: true,
      status: :not_user_data,
      mechanism: nil,
      proof: nil,
      issue: nil,
      note:
        "A derived assembly, not a store: the activity read composes the " <>
          "threads that named the issue with the push, build, target, and " <>
          "deployment receipts reachable from its commit references, and " <>
          "stores nothing of its own. Every record it shows exports through " <>
          "its own family."
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

  @doc "The families this ledger claims cover the published `/api/v1` surface."
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
