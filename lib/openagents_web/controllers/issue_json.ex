defmodule OpenAgentsWeb.IssueJSON do
  @moduledoc """
  Renders GitHub-compatible issue JSON.
  """

  def render("index.json", %{issues: issues} = assigns) do
    %{issues: Enum.map(issues, &issue_json(&1, assigns))}
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
  end

  defp url_base(assigns) do
    Map.get(assigns, :url_base) || String.trim_trailing(OpenAgentsWeb.Endpoint.url(), "/")
  end

  defp translate_error({msg, opts}) do
    Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
      to_string(Keyword.get(opts, String.to_existing_atom(key), key))
    end)
  end
end
