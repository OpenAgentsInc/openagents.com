defmodule OpenAgentsWeb.ApiRouteAuthority do
  @moduledoc """
  The single authority inventory for every `/api/v1` route.

  Each entry names one route and the principal that reaches it. The
  `OpenAgentsWeb.ApiRouteAuthorityTest` proves two ways that this inventory and
  the router agree: every live `/api/v1` route appears here exactly once, so a
  new unclassified route fails CI, and each classification matches what the
  enforcing pipeline actually does to an anonymous request.

  Each entry classifies a route three ways, and all three are mandatory: a
  route added to the router without an entry fails CI, and an entry cannot be
  written without choosing every field.

  Principals:

  - `:anonymous` — no credential is read; anyone may call.
  - `:optional_bearer` — an anonymous caller may read public repositories, and
    a scoped bearer token widens visibility to private repositories the token's
    user can read.
  - `:required_bearer` — a scoped bearer token is mandatory; anonymous calls
    are refused before the controller runs.

  Families name the resource the route serves. They group routes that must
  agree with one another, and `OpenAgentsWeb.ApiExtensionController` publishes
  them at `GET /api/v1` so a client can find every route of a family without
  guessing at paths.

  Error contracts say which refusal shape the route answers with:

  - `:envelope` — every refusal carries the six keys of
    `OpenAgentsWeb.ApiError`. `OpenAgentsWeb.ApiErrorContractTest` dispatches
    each of these routes and fails if the body is anything else.
  - `:legacy` — the route still answers with its own shape. These are the
    families the envelope has not reached yet, named rather than assumed.
  """

  principals = [:anonymous, :optional_bearer, :required_bearer]

  @type principal :: unquote(Enum.reduce(principals, &{:|, [], [&1, &2]}))
  @type error_contract :: :envelope | :legacy
  @type entry :: {principal(), atom(), error_contract()}

  @doc "The authority classification for one `METHOD /path` API v1 route."
  @spec authority(String.t(), String.t()) :: principal() | nil
  def authority(verb, path) do
    case Map.get(inventory(), "#{verb} #{path}") do
      {principal, _family, _contract} -> principal
      nil -> nil
    end
  end

  @doc "The resource family one `METHOD /path` API v1 route belongs to."
  @spec family(String.t(), String.t()) :: atom() | nil
  def family(verb, path) do
    case Map.get(inventory(), "#{verb} #{path}") do
      {_principal, family, _contract} -> family
      nil -> nil
    end
  end

  @doc "The error contract one `METHOD /path` API v1 route answers with."
  @spec error_contract(String.t(), String.t()) :: error_contract() | nil
  def error_contract(verb, path) do
    case Map.get(inventory(), "#{verb} #{path}") do
      {_principal, _family, contract} -> contract
      nil -> nil
    end
  end

  @doc "Every classified route as `{verb, path}` pairs."
  @spec routes() :: [{String.t(), String.t()}]
  def routes do
    Enum.map(inventory(), fn {key, _entry} ->
      key |> String.split(" ", parts: 2) |> List.to_tuple()
    end)
  end

  @doc """
  Every classified route as a map, sorted by path then method.

  This is what `GET /api/v1` publishes. Paths are rewritten from the router's
  `:owner` form into the `{owner}` form the rest of the API description uses,
  so a client reads one spelling everywhere.
  """
  @spec inventory_entries() :: [map()]
  def inventory_entries do
    inventory()
    |> Enum.map(fn {key, {principal, family, contract}} ->
      [verb, path] = String.split(key, " ", parts: 2)

      %{
        "method" => String.upcase(verb),
        "path" => template_path(path),
        "authority" => Atom.to_string(principal),
        "family" => Atom.to_string(family),
        "errors" => Atom.to_string(contract),
        "mutation" => verb not in ["get", "head"]
      }
    end)
    |> Enum.sort_by(&{&1["path"], &1["method"]})
  end

  @doc "Every family this inventory names, sorted."
  @spec families() :: [atom()]
  def families do
    inventory()
    |> Enum.map(fn {_key, {_principal, family, _contract}} -> family end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp template_path(path) do
    Regex.replace(~r/:([a-z_]+)/, path, fn _whole, segment -> "{#{segment}}" end)
  end

  defp inventory do
    %{
      # Anonymous by design: the extension index is a public API description.
      "get /api/v1" => {:anonymous, :meta, :legacy},
      # An anonymous caller is answered as it always was. A caller that
      # presents a `chat:account` bearer is recognized so its own memories are
      # recalled into the turn, which is what makes this optional rather than
      # anonymous. The credential widens the context of the answer, never the
      # authority of the call.
      "post /api/v1/responses" => {:optional_bearer, :response, :envelope},
      # Anonymous by design: device authorization bootstraps credentials.
      "post /api/v1/device/authorizations" => {:anonymous, :device, :legacy},
      "post /api/v1/device/authorizations/token" => {:anonymous, :device, :legacy},
      "post /api/v1/agents/register" => {:anonymous, :agent, :legacy},
      "get /api/v1/agents/:handle" => {:anonymous, :agent, :legacy},
      # Anonymous by design: the CLI discovers validated plugin manifests.
      "get /api/v1/plugins" => {:anonymous, :plugin, :legacy},
      "get /api/v1/plugins/:name" => {:anonymous, :plugin, :legacy},
      # pipe_through :optional_forge_api — public reads, bearer-widened.
      # The ancillary issue metadata reads. Anonymous callers still read public
      # repositories; a bearer token widens them to the private repositories
      # its account may read, so an owner can read their own issue's comments.
      "get /api/v1/repos/:owner/:repo/issues/:issue_number/comments" =>
        {:optional_bearer, :comment, :envelope},
      "get /api/v1/repos/:owner/:repo/issues/comments/:id" =>
        {:optional_bearer, :comment, :envelope},
      "get /api/v1/repos/:owner/:repo/issues/:issue_number/labels" =>
        {:optional_bearer, :issue_label, :envelope},
      "get /api/v1/repos/:owner/:repo/issues/:issue_number/assignees" =>
        {:optional_bearer, :issue_assignee, :envelope},
      "get /api/v1/repos/:owner/:repo/labels" => {:optional_bearer, :label, :envelope},
      "get /api/v1/repos/:owner/:repo/labels/:name" => {:optional_bearer, :label, :envelope},
      "get /api/v1/repos/:owner/:repo/milestones" => {:optional_bearer, :milestone, :envelope},
      "get /api/v1/repos/:owner/:repo/milestones/:milestone_number" =>
        {:optional_bearer, :milestone, :envelope},
      "get /api/v1/repos/:owner/:repo/assignees" => {:optional_bearer, :assignee, :envelope},
      "get /api/v1/repos/:owner/:repo/assignees/:assignee" =>
        {:optional_bearer, :assignee, :envelope},
      "get /api/v1/repos/:owner/:repo/pushes" => {:optional_bearer, :push_receipt, :envelope},
      "get /api/v1/repos/:owner/:repo/pushes/:wal_seq" =>
        {:optional_bearer, :push_receipt, :envelope},
      "get /api/v1/forum" => {:optional_bearer, :forum, :legacy},
      "get /api/v1/forum/topics" => {:optional_bearer, :forum, :legacy},
      "get /api/v1/forum/topics/:id" => {:optional_bearer, :forum, :legacy},
      "get /api/v1/repos/:owner/:repo" => {:optional_bearer, :repository, :legacy},
      "get /api/v1/repos/:owner/:repo/issues" => {:optional_bearer, :issue, :envelope},
      "get /api/v1/repos/:owner/:repo/issues/:issue_number" =>
        {:optional_bearer, :issue, :envelope},
      "get /api/v1/repos/:owner/:repo/issues/:issue_number/activity" =>
        {:optional_bearer, :issue_activity, :envelope},
      "get /api/v1/repos/:owner/:repo/issues/:issue_number/dependencies" =>
        {:optional_bearer, :issue_dependency, :envelope},
      "get /api/v1/repos/:owner/:repo/pulls" => {:optional_bearer, :pull_request, :legacy},
      "get /api/v1/repos/:owner/:repo/pulls/:pull_number" =>
        {:optional_bearer, :pull_request, :legacy},
      "get /api/v1/repos/:owner/:repo/pulls/:pull_number/merge-async/:operation_id" =>
        {:optional_bearer, :stack, :legacy},
      "get /api/v1/repos/:owner/:repo/stacks" => {:optional_bearer, :stack, :legacy},
      "get /api/v1/repos/:owner/:repo/stacks/:stack_number" =>
        {:optional_bearer, :stack, :legacy},
      "get /api/v1/repos/:owner/:repo/stacks/:stack_number/operations/:operation_id" =>
        {:optional_bearer, :stack, :legacy},
      "get /api/v1/repos/:owner/:repo/projectsV2" => {:optional_bearer, :project, :envelope},
      "get /api/v1/repos/:owner/:repo/projectsV2/:project_number" =>
        {:optional_bearer, :project, :envelope},
      "get /api/v1/repos/:owner/:repo/projectsV2/:project_number/items" =>
        {:optional_bearer, :project, :envelope},
      "get /api/v1/repos/:owner/:repo/projectsV2/:project_number/items/:item_id/events" =>
        {:optional_bearer, :project, :envelope},
      "get /api/v1/repos/:owner/:repo/projectsV2/:project_number/fields" =>
        {:optional_bearer, :project, :envelope},
      "get /api/v1/repos/:owner/:repo/projectsV2/:project_number/notes" =>
        {:optional_bearer, :project, :envelope},
      "get /api/v1/reputation/policy" => {:optional_bearer, :reputation, :legacy},
      "get /api/v1/reputation/keys" => {:optional_bearer, :reputation, :legacy},
      "get /api/v1/repos/:owner/:repo/issues/:issue_number/attestations" =>
        {:optional_bearer, :reputation, :legacy},
      "get /api/v1/repos/:owner/:repo/attestations/:id" =>
        {:optional_bearer, :reputation, :legacy},
      "get /api/v1/repos/:owner/:repo/attestations/:id/verification" =>
        {:optional_bearer, :reputation, :legacy},
      "get /api/v1/repos/:owner/:repo/reputation/subjects/:subject_id" =>
        {:optional_bearer, :reputation, :legacy},
      # Scoped bearer pipelines require the route-specific token authority.
      "get /api/v1/chat/events" => {:required_bearer, :chat, :legacy},
      "post /api/v1/chat/turns" => {:required_bearer, :chat, :legacy},
      "get /api/v1/coder/identity" => {:required_bearer, :coder_identity, :legacy},
      "post /api/v1/coder/token" => {:required_bearer, :coder_token, :legacy},
      "post /api/v1/coder/grant" => {:required_bearer, :coder_grant, :legacy},
      "get /api/v1/models" => {:required_bearer, :model, :envelope},
      "get /api/v1/credit" => {:required_bearer, :credit, :envelope},
      "post /api/v1/threads" => {:required_bearer, :thread, :envelope},
      "get /api/v1/threads" => {:required_bearer, :thread, :envelope},
      "get /api/v1/threads/:thread_id" => {:required_bearer, :thread, :envelope},
      "delete /api/v1/threads/:thread_id" => {:required_bearer, :thread, :envelope},
      "post /api/v1/threads/:thread_id/report" => {:required_bearer, :thread, :envelope},
      "get /api/v1/threads/:thread_id/events" => {:required_bearer, :thread, :envelope},
      "post /api/v1/threads/:thread_id/events" => {:required_bearer, :thread, :envelope},
      "post /api/v1/threads/:thread_id/grants" => {:required_bearer, :thread, :envelope},
      "post /api/v1/memories" => {:required_bearer, :memory, :envelope},
      "get /api/v1/memories" => {:required_bearer, :memory, :envelope},
      "delete /api/v1/memories/:id" => {:required_bearer, :memory, :envelope},
      "get /api/v1/capacity" => {:required_bearer, :capacity, :legacy},
      "post /api/v1/capacity/matches" => {:required_bearer, :capacity, :legacy},
      # The bootstrap read for a box client. It answers a conversation, but it
      # belongs to the box family because that is the only reason it exists:
      # every other box route is addressed by conversation id, and this is
      # where a client that holds only `box:control` learns its own.
      "get /api/v1/conversation" => {:required_bearer, :box, :legacy},
      "get /api/v1/conversations/:conversation_id/boxes" => {:required_bearer, :box, :legacy},
      "post /api/v1/conversations/:conversation_id/boxes" => {:required_bearer, :box, :legacy},
      "post /api/v1/conversations/:conversation_id/boxes/fanout" =>
        {:required_bearer, :box, :legacy},
      "get /api/v1/conversations/:conversation_id/boxes/fanout/:request_id" =>
        {:required_bearer, :box, :legacy},
      "get /api/v1/conversations/:conversation_id/boxes/:box_id" =>
        {:required_bearer, :box, :legacy},
      "post /api/v1/conversations/:conversation_id/boxes/:box_id/commands" =>
        {:required_bearer, :box, :legacy},
      "post /api/v1/conversations/:conversation_id/boxes/:box_id/stop" =>
        {:required_bearer, :box, :legacy},
      "post /api/v1/conversations/:conversation_id/boxes/:box_id/assignments" =>
        {:required_bearer, :assignment, :legacy},
      "get /api/v1/conversations/:conversation_id/boxes/:box_id/assignments/:assignment_id" =>
        {:required_bearer, :assignment, :legacy},
      "post /api/v1/conversations/:conversation_id/boxes/:box_id/assignments/:assignment_id/cancel" =>
        {:required_bearer, :assignment, :legacy},
      "post /api/v1/conversations/:conversation_id/computers/:computer_id/assignments" =>
        {:required_bearer, :assignment, :legacy},
      "get /api/v1/conversations/:conversation_id/computers/:computer_id/assignments/:assignment_id" =>
        {:required_bearer, :assignment, :legacy},
      "post /api/v1/conversations/:conversation_id/computers/:computer_id/assignments/:assignment_id/cancel" =>
        {:required_bearer, :assignment, :legacy},
      "post /api/v1/conversations/:conversation_id/boxes/:box_id/runs" =>
        {:required_bearer, :box, :legacy},
      "get /api/v1/conversations/:conversation_id/boxes/:box_id/runs" =>
        {:required_bearer, :box, :legacy},
      "get /api/v1/conversations/:conversation_id/boxes/:box_id/runs/:run_id" =>
        {:required_bearer, :box, :legacy},
      "get /api/v1/conversations/:conversation_id/boxes/:box_id/runs/:run_id/output" =>
        {:required_bearer, :box, :legacy},
      "post /api/v1/conversations/:conversation_id/boxes/:box_id/runs/:run_id/cancel" =>
        {:required_bearer, :box, :legacy},
      "get /api/v1/computers" => {:required_bearer, :computer, :legacy},
      "patch /api/v1/computers/:id" => {:required_bearer, :computer, :legacy},
      "post /api/v1/computers/:computer_id/probe" => {:required_bearer, :computer, :legacy},
      "post /api/v1/computers/:computer_id/agent-jobs" => {:required_bearer, :computer, :legacy},
      "get /api/v1/computer-agent-jobs/:id" => {:required_bearer, :computer, :legacy},
      "delete /api/v1/computer-agent-jobs/:id" => {:required_bearer, :computer, :legacy},
      "get /api/v1/conversations/:conversation_id/delegation-targets" =>
        {:required_bearer, :delegation, :legacy},
      "post /api/v1/conversations/:conversation_id/delegations" =>
        {:required_bearer, :delegation, :legacy},
      "get /api/v1/conversations/:conversation_id/delegations/:id" =>
        {:required_bearer, :delegation, :legacy},
      "delete /api/v1/conversations/:conversation_id/delegations/:id" =>
        {:required_bearer, :delegation, :legacy},
      "delete /api/v1/repos/:owner/:repo" => {:required_bearer, :repository, :legacy},
      "delete /api/v1/repos/:owner/:repo/issues/:issue_number/assignees" =>
        {:required_bearer, :issue_assignee, :envelope},
      "delete /api/v1/repos/:owner/:repo/issues/:issue_number/labels/:name" =>
        {:required_bearer, :issue_label, :envelope},
      "delete /api/v1/repos/:owner/:repo/issues/comments/:id" =>
        {:required_bearer, :comment, :envelope},
      "delete /api/v1/repos/:owner/:repo/labels/:name" => {:required_bearer, :label, :envelope},
      "delete /api/v1/repos/:owner/:repo/milestones/:milestone_number" =>
        {:required_bearer, :milestone, :envelope},
      "get /api/v1/repository-imports/:id" => {:required_bearer, :repository, :legacy},
      "get /api/v1/user" => {:required_bearer, :repository, :legacy},
      "get /api/v1/user/repos" => {:required_bearer, :repository, :legacy},
      "patch /api/v1/repos/:owner/:repo/issues/:issue_number" =>
        {:required_bearer, :issue, :envelope},
      "patch /api/v1/repos/:owner/:repo" => {:required_bearer, :repository, :legacy},
      "patch /api/v1/repos/:owner/:repo/pulls/:pull_number" =>
        {:required_bearer, :pull_request, :legacy},
      "patch /api/v1/repos/:owner/:repo/issues/comments/:id" =>
        {:required_bearer, :comment, :envelope},
      "patch /api/v1/repos/:owner/:repo/labels/:name" => {:required_bearer, :label, :envelope},
      "patch /api/v1/repos/:owner/:repo/milestones/:milestone_number" =>
        {:required_bearer, :milestone, :envelope},
      "patch /api/v1/repos/:owner/:repo/projectsV2/:project_number/items/:item_id" =>
        {:required_bearer, :project, :envelope},
      "post /api/v1/repos" => {:required_bearer, :repository, :legacy},
      "post /api/v1/orgs/:org/repos" => {:required_bearer, :repository, :legacy},
      "post /api/v1/orgs/:org/repos/imports" => {:required_bearer, :repository, :legacy},
      "post /api/v1/repos/:owner/:repo/pulls" => {:required_bearer, :pull_request, :legacy},
      "put /api/v1/repos/:owner/:repo/pulls/:pull_number/merge-async" =>
        {:required_bearer, :stack, :legacy},
      "post /api/v1/repos/:owner/:repo/stacks" => {:required_bearer, :stack, :legacy},
      "post /api/v1/repos/:owner/:repo/stacks/:stack_number/append" =>
        {:required_bearer, :stack, :legacy},
      "post /api/v1/repos/:owner/:repo/stacks/:stack_number/unstack" =>
        {:required_bearer, :stack, :legacy},
      "post /api/v1/repos/:owner/:repo/stacks/:stack_number/dissolve" =>
        {:required_bearer, :stack, :legacy},
      "post /api/v1/repos/:owner/:repo/stacks/:stack_number/rebase" =>
        {:required_bearer, :stack, :legacy},
      "post /api/v1/repos/:owner/:repo/stacks/:stack_number/merge" =>
        {:required_bearer, :stack, :legacy},
      "post /api/v1/repos/:owner/:repo/stacks/:stack_number/operations/:operation_id/continue" =>
        {:required_bearer, :stack, :legacy},
      "post /api/v1/repos/:owner/:repo/stacks/:stack_number/operations/:operation_id/abort" =>
        {:required_bearer, :stack, :legacy},
      # pipe_through :fleet_promotion_api — operator-only fleet promotion. The
      # bearer must carry `deployments:promote` and its account must be a
      # current operator, so no tenant credential reaches these three routes.
      "post /api/v1/admin/forge/targets" => {:required_bearer, :fleet_target, :envelope},
      "get /api/v1/admin/forge/targets" => {:required_bearer, :fleet_target, :envelope},
      "get /api/v1/admin/forge/targets/:id" => {:required_bearer, :fleet_target, :envelope},
      # pipe_through :deployments_api — tenant deployment authority only. No
      # route here is anonymous, and none of them reaches the operator fleet
      # promotion surface.
      "get /api/v1/repos/:owner/:repo/deployment-environments" =>
        {:required_bearer, :deployment, :legacy},
      "put /api/v1/repos/:owner/:repo/deployment-environments/:name" =>
        {:required_bearer, :deployment, :legacy},
      "get /api/v1/repos/:owner/:repo/deployment-environments/:name/protection" =>
        {:required_bearer, :deployment, :legacy},
      "post /api/v1/repos/:owner/:repo/deployments" => {:required_bearer, :deployment, :legacy},
      "get /api/v1/repos/:owner/:repo/deployments" => {:required_bearer, :deployment, :legacy},
      "get /api/v1/repos/:owner/:repo/deployments/:id" =>
        {:required_bearer, :deployment, :legacy},
      "post /api/v1/repos/:owner/:repo/deployments/:id/cancel" =>
        {:required_bearer, :deployment, :legacy},
      "post /api/v1/repos/:owner/:repo/deployments/:id/approvals" =>
        {:required_bearer, :deployment, :legacy},
      "get /api/v1/repos/:owner/:repo/deployments/:id/approvals" =>
        {:required_bearer, :deployment, :legacy},
      "get /api/v1/repos/:owner/:repo/deployments/:id/events" =>
        {:required_bearer, :deployment, :legacy},
      "post /api/v1/repos/:owner/:repo/deployment-checks" =>
        {:required_bearer, :deployment, :legacy},
      "post /api/v1/repos/:owner/:repo/deployment-workflow-grants" =>
        {:required_bearer, :deployment, :legacy},
      "delete /api/v1/repos/:owner/:repo/deployment-workflow-grants/:id" =>
        {:required_bearer, :deployment, :legacy},
      # Dual-principal participation writes accept either a human forge token or
      # an agent participation credential.
      "post /api/v1/forum/topics" => {:required_bearer, :forum, :legacy},
      "post /api/v1/forum/topics/:topic_id/posts" => {:required_bearer, :forum, :legacy},
      "post /api/v1/repos/:owner/:repo/issues" => {:required_bearer, :issue, :envelope},
      "post /api/v1/repos/:owner/:repo/issues/capture" => {:required_bearer, :issue, :envelope},
      "post /api/v1/repos/:owner/:repo/issues/:issue_number/comments" =>
        {:required_bearer, :comment, :envelope},
      "post /api/v1/repos/:owner/:repo/issues/:issue_number/completion_claim" =>
        {:required_bearer, :issue, :envelope},
      "get /api/v1/agent" => {:required_bearer, :agent, :legacy},
      "post /api/v1/agents/:handle/box-control" => {:required_bearer, :agent, :legacy},
      "post /api/v1/gym/runs" => {:required_bearer, :gym, :envelope},
      "post /api/v1/gym/runs/start" => {:required_bearer, :gym, :envelope},
      "post /api/v1/gym/runs/:id/trials" => {:required_bearer, :gym, :envelope},
      "patch /api/v1/gym/runs/:id" => {:required_bearer, :gym, :envelope},
      "get /api/v1/gym/runs" => {:required_bearer, :gym, :envelope},
      "delete /api/v1/agents/:handle/box-control" => {:required_bearer, :agent, :legacy},
      "post /api/v1/agents/:handle/computer-control" => {:required_bearer, :agent, :legacy},
      "delete /api/v1/agents/:handle/computer-control" => {:required_bearer, :agent, :legacy},
      "post /api/v1/agent/credentials" => {:required_bearer, :agent, :legacy},
      "post /api/v1/agent/links" => {:required_bearer, :agent, :legacy},
      "get /api/v1/agents/links" => {:required_bearer, :agent, :legacy},
      "post /api/v1/agents/links/:id/accept" => {:required_bearer, :agent, :legacy},
      "post /api/v1/agents/links/:id/reject" => {:required_bearer, :agent, :legacy},
      "delete /api/v1/agents/links/:id" => {:required_bearer, :agent, :legacy},
      "post /api/v1/forum/claims" => {:required_bearer, :forum, :legacy},
      "get /api/v1/forum/claims" => {:required_bearer, :forum, :legacy},
      "post /api/v1/reputation/subject-claims" => {:required_bearer, :reputation, :legacy},
      "get /api/v1/reputation/subject-claims" => {:required_bearer, :reputation, :legacy},
      "get /api/v1/reputation/subject-claims/pending" => {:required_bearer, :reputation, :legacy},
      "patch /api/v1/reputation/subject-claims/:id" => {:required_bearer, :reputation, :legacy},
      # Moderation and claim review: a bearer the controller then checks for
      # operator authority.
      "patch /api/v1/forum/topics/:id" => {:required_bearer, :forum, :legacy},
      "patch /api/v1/forum/posts/:id" => {:required_bearer, :forum, :legacy},
      "get /api/v1/forum/claims/pending" => {:required_bearer, :forum, :legacy},
      "patch /api/v1/forum/claims/:id" => {:required_bearer, :forum, :legacy},
      # Tips: a destination, a payment, and a settlement history each belong to
      # one account, so anonymous callers never reach them.
      "post /api/v1/forum/tips/destination" => {:required_bearer, :forum, :legacy},
      "patch /api/v1/forum/tips/destination" => {:required_bearer, :forum, :legacy},
      "get /api/v1/forum/tips/destination" => {:required_bearer, :forum, :legacy},
      "get /api/v1/forum/tips/received" => {:required_bearer, :forum, :legacy},
      "post /api/v1/forum/posts/:post_id/tips" => {:required_bearer, :forum, :legacy},
      "post /api/v1/repos/:owner/:repo/issues/:issue_number/assignees" =>
        {:required_bearer, :issue_assignee, :envelope},
      "post /api/v1/repos/:owner/:repo/issues/:issue_number/dependencies" =>
        {:required_bearer, :issue_dependency, :envelope},
      "delete /api/v1/repos/:owner/:repo/issues/:issue_number/dependencies/:blocked_by_number" =>
        {:required_bearer, :issue_dependency, :envelope},
      "post /api/v1/repos/:owner/:repo/issues/:issue_number/labels" =>
        {:required_bearer, :issue_label, :envelope},
      "post /api/v1/repos/:owner/:repo/labels" => {:required_bearer, :label, :envelope},
      "post /api/v1/repos/:owner/:repo/milestones" => {:required_bearer, :milestone, :envelope},
      "post /api/v1/repos/:owner/:repo/projectsV2" => {:required_bearer, :project, :envelope},
      "post /api/v1/repos/:owner/:repo/projectsV2/:project_number/items" =>
        {:required_bearer, :project, :envelope},
      "post /api/v1/repos/:owner/:repo/projectsV2/:project_number/items/:item_id/move" =>
        {:required_bearer, :project, :envelope},
      "delete /api/v1/repos/:owner/:repo/projectsV2/:project_number/items/:item_id" =>
        {:required_bearer, :project, :envelope},
      "post /api/v1/repos/:owner/:repo/projectsV2/:project_number/fields" =>
        {:required_bearer, :project, :envelope},
      "patch /api/v1/repos/:owner/:repo/projectsV2/:project_number" =>
        {:required_bearer, :project, :envelope},
      "post /api/v1/repos/:owner/:repo/projectsV2/:project_number/notes" =>
        {:required_bearer, :project, :envelope},
      "patch /api/v1/repos/:owner/:repo/projectsV2/:project_number/notes/:note_id" =>
        {:required_bearer, :project, :envelope},
      "delete /api/v1/repos/:owner/:repo/projectsV2/:project_number/notes/:note_id" =>
        {:required_bearer, :project, :envelope},
      "patch /api/v1/repos/:owner/:repo/projectsV2/:project_number/fields/:field_id" =>
        {:required_bearer, :project, :envelope},
      "delete /api/v1/repos/:owner/:repo/projectsV2/:project_number/fields/:field_id" =>
        {:required_bearer, :project, :envelope},
      "delete /api/v1/repos/:owner/:repo/projectsV2/:project_number" =>
        {:required_bearer, :project, :envelope},
      "post /api/v1/user/repos" => {:required_bearer, :repository, :legacy},
      "post /api/v1/user/repos/imports" => {:required_bearer, :repository, :legacy},
      "put /api/v1/repos/:owner/:repo/issues/:issue_number" =>
        {:required_bearer, :issue, :envelope},
      "put /api/v1/repos/:owner/:repo/issues/comments/:id" =>
        {:required_bearer, :comment, :envelope},
      "put /api/v1/repos/:owner/:repo/labels/:name" => {:required_bearer, :label, :envelope},
      "put /api/v1/repos/:owner/:repo/milestones/:milestone_number" =>
        {:required_bearer, :milestone, :envelope},
      # Landed under the old prefix while the rename was in flight. It moves
      # with everything else; the alias answers the prefix it was written
      # against until that alias goes away.
      "post /api/v1/traces" => {:required_bearer, :trace, :envelope}
    }
  end
end
