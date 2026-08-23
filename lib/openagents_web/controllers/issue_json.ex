defmodule OpenAgentsWeb.IssueJSON do
  @moduledoc """
  Renders GitHub-compatible issue JSON.

  GitHub-shaped keys keep their exact shape. OpenAgents-specific fields live
  under one `openagents` object, so a GitHub client sees an additional object
  and nothing else. The object appears only when the caller supplies the
  `:dependencies` graph, because an absent graph is not the same fact as an
  issue with no prerequisites.
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

  def render("error.json", %{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
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
    case Map.get(assigns, :dependencies) do
      nil -> json
      graph -> Map.put(json, :openagents, extension_json(graph, issue))
    end
  end

  defp extension_json(graph, issue) do
    dependencies = Map.get(graph, issue.id, %{blocked: false, blocked_by: [], blocks: []})

    %{
      blocked: dependencies.blocked,
      blocked_by: dependencies.blocked_by,
      blocks: dependencies.blocks
    }
  end

  defp total_pages(0, _per_page), do: 1

  defp total_pages(total, per_page), do: ceil(total / per_page)

  defp url_base(assigns) do
    Map.get(assigns, :url_base) || String.trim_trailing(OpenAgentsWeb.Endpoint.url(), "/")
  end

  defp translate_error({msg, opts}) do
    Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
      to_string(Keyword.get(opts, String.to_existing_atom(key), key))
    end)
  end
end
