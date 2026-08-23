defmodule OpenAgentsWeb.IssueJSON do
  @moduledoc """
  Renders GitHub-compatible issue JSON.

  GitHub-shaped keys keep their exact shape. OpenAgents-specific fields live
  under one `openagents` object, so a GitHub client sees an additional object
  and nothing else. Each field appears only when the caller supplies it, and
  the object appears only when at least one field does: an absent dependency
  graph is not the same fact as an issue with no prerequisites, and an absent
  progress derivation is not the same fact as an issue nobody has started.

  Every key this module can put inside the object is enumerated at
  `GET /api/v3`, and `OpenAgentsWeb.ApiExtensionGovernanceTest` fails if one
  is not.
  """

  def render("index.json", %{issues: issues, pagination: pagination} = assigns) do
    %{
      issues: Enum.map(issues, &issue_json(&1, assigns)),
      pagination: %{
        page: pagination.page,
        per_page: pagination.per_page,
        total: pagination.total,
        total_pages: total_pages(pagination.total, pagination.per_page)
      }
    }
  end

  def render("show.json", %{issue: issue} = assigns) do
    issue_json(issue, assigns)
  end

  defp issue_json(issue, assigns) do
    owner = Map.get(assigns, :owner, "OpenAgents")
    repo = Map.get(assigns, :repo, "openagents")
    url_base = url_base(assigns)

    %{
      id: issue.id,
      node_id: "I_#{issue.id}",
      number: issue.number,
      title: issue.title,
      body: issue.body,
      state: issue.state,
      state_reason: issue.state_reason,
      locked: issue.locked,
      comments: issue.comments,
      labels: issue.labels || [],
      assignees: issue.assignees || [],
      milestone: issue.milestone,
      user: issue.user,
      created_at: issue.inserted_at,
      updated_at: issue.updated_at,
      closed_at: issue.closed_at,
      html_url: "#{url_base}/#{owner}/#{repo}/issues/#{issue.number}",
      url: "#{url_base}/api/v3/repos/#{owner}/#{repo}/issues/#{issue.number}"
    }
    |> put_extension(issue, assigns)
  end

  defp put_extension(json, issue, assigns) do
    extension =
      %{}
      |> put_dependencies(Map.get(assigns, :dependencies), issue)
      |> put_progress(Map.get(assigns, :progress), issue)

    if extension == %{}, do: json, else: Map.put(json, :openagents, extension)
  end

  defp put_dependencies(extension, nil, _issue), do: extension

  defp put_dependencies(extension, graph, issue) do
    dependencies = Map.get(graph, issue.id, %{blocked: false, blocked_by: [], blocks: []})

    Map.merge(extension, %{
      blocked: dependencies.blocked,
      blocked_by: dependencies.blocked_by,
      blocks: dependencies.blocks
    })
  end

  defp put_progress(extension, nil, _issue), do: extension

  defp put_progress(extension, progress, issue) when is_map(progress),
    do: Map.put(extension, :progress, Map.get(progress, issue.id, "to_do"))

  defp total_pages(0, _per_page), do: 1

  defp total_pages(total, per_page), do: ceil(total / per_page)

  defp url_base(assigns) do
    Map.get(assigns, :url_base) || String.trim_trailing(OpenAgentsWeb.Endpoint.url(), "/")
  end
end
