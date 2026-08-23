defmodule OpenAgentsWeb.MilestoneJSON do
  @moduledoc """
  Renders GitHub-compatible milestone JSON.
  """

  def render("index.json", %{milestones: milestones} = assigns) do
    %{milestones: Enum.map(milestones, &milestone_json(&1, assigns))}
  end

  def render("show.json", %{milestone: milestone} = assigns) do
    milestone_json(milestone, assigns)
  end

  defp milestone_json(milestone, assigns) do
    owner = Map.get(assigns, :owner, "OpenAgents")
    repo = Map.get(assigns, :repo, "openagents")

    %{
      id: milestone.id,
      number: milestone.number,
      title: milestone.title,
      state: milestone.state,
      description: milestone.description,
      due_on: milestone.due_on,
      open_issues: milestone.open_issues,
      closed_issues: milestone.closed_issues,
      url: "#{url_base(assigns)}/api/v3/repos/#{owner}/#{repo}/milestones/#{milestone.number}"
    }
  end

  defp url_base(assigns) do
    Map.get(assigns, :url_base) || String.trim_trailing(OpenAgentsWeb.Endpoint.url(), "/")
  end
end
