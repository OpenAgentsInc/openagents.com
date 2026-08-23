defmodule OpenAgentsWeb.ApiRouteAuthority do
  @moduledoc """
  The single authority inventory for every `/api/v3` route.

  Each entry names one route and the principal that reaches it. The
  `OpenAgentsWeb.ApiRouteAuthorityTest` proves two ways that this inventory and
  the router agree: every live `/api/v3` route appears here exactly once, so a
  new unclassified route fails CI, and each classification matches what the
  enforcing pipeline actually does to an anonymous request.

  Principals:

  - `:anonymous` — no credential is read; anyone may call.
  - `:optional_bearer` — an anonymous caller may read public repositories, and
    a scoped bearer token widens visibility to private repositories the token's
    user can read.
  - `:required_bearer` — a scoped bearer token is mandatory; anonymous calls
    are refused before the controller runs.
  """

  principals = [:anonymous, :optional_bearer, :required_bearer]

  @type principal :: unquote(Enum.reduce(principals, &{:|, [], [&1, &2]}))

  @doc "The authority classification for one `METHOD /path` API v3 route."
  @spec authority(String.t(), String.t()) :: principal() | nil
  def authority(verb, path) do
    Map.get(inventory(), "#{verb} #{path}")
  end

  @doc "Every classified route as `{verb, path}` pairs."
  @spec routes() :: [{String.t(), String.t()}]
  def routes do
    Enum.map(inventory(), fn {key, _principal} ->
      key |> String.split(" ", parts: 2) |> List.to_tuple()
    end)
  end

  defp inventory do
    %{
      # pipe_through :api — anonymous reads over public repositories.
      "get /api/v3/repos/:owner/:repo/issues/:issue_number/comments" => :anonymous,
      "get /api/v3/repos/:owner/:repo/issues/comments/:id" => :anonymous,
      "get /api/v3/repos/:owner/:repo/issues/:issue_number/labels" => :anonymous,
      "get /api/v3/repos/:owner/:repo/issues/:issue_number/assignees" => :anonymous,
      "get /api/v3/repos/:owner/:repo/labels" => :anonymous,
      "get /api/v3/repos/:owner/:repo/labels/:name" => :anonymous,
      "get /api/v3/repos/:owner/:repo/milestones" => :anonymous,
      "get /api/v3/repos/:owner/:repo/milestones/:milestone_number" => :anonymous,
      "get /api/v3/repos/:owner/:repo/assignees" => :anonymous,
      "get /api/v3/repos/:owner/:repo/assignees/:assignee" => :anonymous,
      # Anonymous by design: the extension index is a public API description.
      "get /api/v3" => :anonymous,
      # Anonymous by design: device authorization bootstraps credentials.
      "post /api/v3/device/authorizations" => :anonymous,
      "post /api/v3/device/authorizations/token" => :anonymous,
      "post /api/v3/agents/register" => :anonymous,
      "get /api/v3/agents/:handle" => :anonymous,
      # pipe_through :optional_forge_api — public reads, bearer-widened.
      "get /api/v3/forum" => :optional_bearer,
      "get /api/v3/forum/topics" => :optional_bearer,
      "get /api/v3/forum/topics/:id" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/issues" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/issues/:issue_number" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/issues/:issue_number/dependencies" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/pulls" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/pulls/:pull_number" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/pulls/:pull_number/merge-async/:operation_id" =>
        :optional_bearer,
      "get /api/v3/repos/:owner/:repo/stacks" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/stacks/:stack_number" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/stacks/:stack_number/operations/:operation_id" =>
        :optional_bearer,
      "get /api/v3/repos/:owner/:repo/projectsV2" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/projectsV2/:project_number" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/projectsV2/:project_number/items" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/projectsV2/:project_number/items/:item_id/events" =>
        :optional_bearer,
      "get /api/v3/repos/:owner/:repo/projectsV2/:project_number/fields" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/projectsV2/:project_number/notes" => :optional_bearer,
      "get /api/v3/reputation/policy" => :optional_bearer,
      "get /api/v3/reputation/keys" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/issues/:issue_number/attestations" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/attestations/:id" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/attestations/:id/verification" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/reputation/subjects/:subject_id" => :optional_bearer,
      # Scoped bearer pipelines require the route-specific token authority.
      "get /api/v3/chat/events" => :required_bearer,
      "post /api/v3/chat/turns" => :required_bearer,
      "get /api/v3/capacity" => :required_bearer,
      "post /api/v3/capacity/matches" => :required_bearer,
      "get /api/v3/conversations/:conversation_id/boxes" => :required_bearer,
      "post /api/v3/conversations/:conversation_id/boxes" => :required_bearer,
      "post /api/v3/conversations/:conversation_id/boxes/fanout" => :required_bearer,
      "get /api/v3/conversations/:conversation_id/boxes/fanout/:request_id" => :required_bearer,
      "get /api/v3/conversations/:conversation_id/boxes/:box_id" => :required_bearer,
      "post /api/v3/conversations/:conversation_id/boxes/:box_id/commands" => :required_bearer,
      "post /api/v3/conversations/:conversation_id/boxes/:box_id/stop" => :required_bearer,
      "post /api/v3/conversations/:conversation_id/boxes/:box_id/assignments" => :required_bearer,
      "get /api/v3/conversations/:conversation_id/boxes/:box_id/assignments/:assignment_id" =>
        :required_bearer,
      "post /api/v3/conversations/:conversation_id/boxes/:box_id/assignments/:assignment_id/cancel" =>
        :required_bearer,
      "post /api/v3/conversations/:conversation_id/boxes/:box_id/runs" => :required_bearer,
      "get /api/v3/conversations/:conversation_id/boxes/:box_id/runs" => :required_bearer,
      "get /api/v3/conversations/:conversation_id/boxes/:box_id/runs/:run_id" => :required_bearer,
      "get /api/v3/conversations/:conversation_id/boxes/:box_id/runs/:run_id/output" =>
        :required_bearer,
      "post /api/v3/conversations/:conversation_id/boxes/:box_id/runs/:run_id/cancel" =>
        :required_bearer,
      "get /api/v3/computers" => :required_bearer,
      "post /api/v3/computers/:machine_id/probe" => :required_bearer,
      "post /api/v3/computers/:machine_id/agent-jobs" => :required_bearer,
      "get /api/v3/computer-agent-jobs/:id" => :required_bearer,
      "delete /api/v3/computer-agent-jobs/:id" => :required_bearer,
      "get /api/v3/conversations/:conversation_id/delegation-targets" => :required_bearer,
      "post /api/v3/conversations/:conversation_id/delegations" => :required_bearer,
      "get /api/v3/conversations/:conversation_id/delegations/:id" => :required_bearer,
      "delete /api/v3/conversations/:conversation_id/delegations/:id" => :required_bearer,
      "delete /api/v3/repos/:owner/:repo" => :required_bearer,
      "delete /api/v3/repos/:owner/:repo/issues/:issue_number/assignees" => :required_bearer,
      "delete /api/v3/repos/:owner/:repo/issues/:issue_number/labels/:name" => :required_bearer,
      "delete /api/v3/repos/:owner/:repo/issues/comments/:id" => :required_bearer,
      "delete /api/v3/repos/:owner/:repo/labels/:name" => :required_bearer,
      "delete /api/v3/repos/:owner/:repo/milestones/:milestone_number" => :required_bearer,
      "get /api/v3/repository-imports/:id" => :required_bearer,
      "get /api/v3/user" => :required_bearer,
      "get /api/v3/user/repos" => :required_bearer,
      "patch /api/v3/repos/:owner/:repo/issues/:issue_number" => :required_bearer,
      "patch /api/v3/repos/:owner/:repo" => :required_bearer,
      "patch /api/v3/repos/:owner/:repo/pulls/:pull_number" => :required_bearer,
      "patch /api/v3/repos/:owner/:repo/issues/comments/:id" => :required_bearer,
      "patch /api/v3/repos/:owner/:repo/labels/:name" => :required_bearer,
      "patch /api/v3/repos/:owner/:repo/milestones/:milestone_number" => :required_bearer,
      "patch /api/v3/repos/:owner/:repo/projectsV2/:project_number/items/:item_id" =>
        :required_bearer,
      "post /api/v3/orgs/:org/repos" => :required_bearer,
      "post /api/v3/orgs/:org/repos/imports" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/pulls" => :required_bearer,
      "put /api/v3/repos/:owner/:repo/pulls/:pull_number/merge-async" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/stacks" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/stacks/:stack_number/append" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/stacks/:stack_number/unstack" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/stacks/:stack_number/dissolve" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/stacks/:stack_number/rebase" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/stacks/:stack_number/merge" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/stacks/:stack_number/operations/:operation_id/continue" =>
        :required_bearer,
      "post /api/v3/repos/:owner/:repo/stacks/:stack_number/operations/:operation_id/abort" =>
        :required_bearer,
      # pipe_through :deployments_api — tenant deployment authority only. No
      # route here is anonymous, and none of them reaches the operator fleet
      # promotion surface.
      "get /api/v3/repos/:owner/:repo/deployment-environments" => :required_bearer,
      "put /api/v3/repos/:owner/:repo/deployment-environments/:name" => :required_bearer,
      "get /api/v3/repos/:owner/:repo/deployment-environments/:name/protection" =>
        :required_bearer,
      "post /api/v3/repos/:owner/:repo/deployments" => :required_bearer,
      "get /api/v3/repos/:owner/:repo/deployments" => :required_bearer,
      "get /api/v3/repos/:owner/:repo/deployments/:id" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/deployments/:id/cancel" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/deployments/:id/approvals" => :required_bearer,
      "get /api/v3/repos/:owner/:repo/deployments/:id/approvals" => :required_bearer,
      "get /api/v3/repos/:owner/:repo/deployments/:id/events" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/deployment-checks" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/deployment-workflow-grants" => :required_bearer,
      "delete /api/v3/repos/:owner/:repo/deployment-workflow-grants/:id" => :required_bearer,
      # Dual-principal participation writes accept either a human forge token or
      # an agent participation credential.
      "post /api/v3/forum/topics" => :required_bearer,
      "post /api/v3/forum/topics/:topic_id/posts" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/issues" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/issues/:issue_number/comments" => :required_bearer,
      "get /api/v3/agent" => :required_bearer,
      "post /api/v3/agents/:handle/box-control" => :required_bearer,
      "delete /api/v3/agents/:handle/box-control" => :required_bearer,
      "post /api/v3/agents/:handle/computer-control" => :required_bearer,
      "delete /api/v3/agents/:handle/computer-control" => :required_bearer,
      "post /api/v3/agent/credentials" => :required_bearer,
      "post /api/v3/agent/links" => :required_bearer,
      "get /api/v3/agents/links" => :required_bearer,
      "post /api/v3/agents/links/:id/accept" => :required_bearer,
      "post /api/v3/agents/links/:id/reject" => :required_bearer,
      "delete /api/v3/agents/links/:id" => :required_bearer,
      "post /api/v3/forum/claims" => :required_bearer,
      "get /api/v3/forum/claims" => :required_bearer,
      # Moderation and claim review: a bearer the controller then checks for
      # operator authority.
      "patch /api/v3/forum/topics/:id" => :required_bearer,
      "patch /api/v3/forum/posts/:id" => :required_bearer,
      "get /api/v3/forum/claims/pending" => :required_bearer,
      "patch /api/v3/forum/claims/:id" => :required_bearer,
      # Tips: a destination, a payment, and a settlement history each belong to
      # one account, so anonymous callers never reach them.
      "post /api/v3/forum/tips/destination" => :required_bearer,
      "patch /api/v3/forum/tips/destination" => :required_bearer,
      "get /api/v3/forum/tips/destination" => :required_bearer,
      "get /api/v3/forum/tips/received" => :required_bearer,
      "post /api/v3/forum/posts/:post_id/tips" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/issues/:issue_number/assignees" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/issues/:issue_number/dependencies" => :required_bearer,
      "delete /api/v3/repos/:owner/:repo/issues/:issue_number/dependencies/:blocked_by_number" =>
        :required_bearer,
      "post /api/v3/repos/:owner/:repo/issues/:issue_number/labels" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/labels" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/milestones" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/projectsV2" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/projectsV2/:project_number/items" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/projectsV2/:project_number/fields" => :required_bearer,
      "patch /api/v3/repos/:owner/:repo/projectsV2/:project_number" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/projectsV2/:project_number/notes" => :required_bearer,
      "patch /api/v3/repos/:owner/:repo/projectsV2/:project_number/notes/:note_id" =>
        :required_bearer,
      "delete /api/v3/repos/:owner/:repo/projectsV2/:project_number/notes/:note_id" =>
        :required_bearer,
      "post /api/v3/user/repos" => :required_bearer,
      "post /api/v3/user/repos/imports" => :required_bearer,
      "put /api/v3/repos/:owner/:repo/issues/:issue_number" => :required_bearer,
      "put /api/v3/repos/:owner/:repo/issues/comments/:id" => :required_bearer,
      "put /api/v3/repos/:owner/:repo/labels/:name" => :required_bearer,
      "put /api/v3/repos/:owner/:repo/milestones/:milestone_number" => :required_bearer
    }
  end
end
