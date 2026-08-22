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
      # Anonymous by design: device authorization bootstraps credentials.
      "post /api/v3/device/authorizations" => :anonymous,
      "post /api/v3/device/authorizations/token" => :anonymous,
      # pipe_through :optional_forge_api — public reads, bearer-widened.
      "get /api/v3/forum" => :optional_bearer,
      "get /api/v3/forum/topics" => :optional_bearer,
      "get /api/v3/forum/topics/:id" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/issues" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/issues/:issue_number" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/projectsV2" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/projectsV2/:project_number" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/projectsV2/:project_number/items" => :optional_bearer,
      "get /api/v3/repos/:owner/:repo/projectsV2/:project_number/fields" => :optional_bearer,
      # pipe_through :forge_write_api — scoped bearer required.
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
      "patch /api/v3/repos/:owner/:repo/issues/comments/:id" => :required_bearer,
      "patch /api/v3/repos/:owner/:repo/labels/:name" => :required_bearer,
      "patch /api/v3/repos/:owner/:repo/milestones/:milestone_number" => :required_bearer,
      "patch /api/v3/repos/:owner/:repo/projectsV2/:project_number/items/:item_id" =>
        :required_bearer,
      "post /api/v3/orgs/:org/repos" => :required_bearer,
      "post /api/v3/orgs/:org/repos/imports" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/issues" => :required_bearer,
      # pipe_through :forge_write_api — forum writes and identity claims.
      "post /api/v3/forum/topics" => :required_bearer,
      "post /api/v3/forum/topics/:topic_id/posts" => :required_bearer,
      "post /api/v3/forum/claims" => :required_bearer,
      "get /api/v3/forum/claims" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/issues/:issue_number/assignees" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/issues/:issue_number/comments" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/issues/:issue_number/labels" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/labels" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/milestones" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/projectsV2" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/projectsV2/:project_number/items" => :required_bearer,
      "post /api/v3/repos/:owner/:repo/projectsV2/:project_number/fields" => :required_bearer,
      "post /api/v3/user/repos" => :required_bearer,
      "post /api/v3/user/repos/imports" => :required_bearer,
      "put /api/v3/repos/:owner/:repo/issues/:issue_number" => :required_bearer,
      "put /api/v3/repos/:owner/:repo/issues/comments/:id" => :required_bearer,
      "put /api/v3/repos/:owner/:repo/labels/:name" => :required_bearer,
      "put /api/v3/repos/:owner/:repo/milestones/:milestone_number" => :required_bearer
    }
  end
end
