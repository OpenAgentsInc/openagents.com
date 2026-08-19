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

  def render("error.json", %{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
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
      open_issues: 0,
      closed_issues: 0,
      url: "https://openagents.com/api/v3/repos/#{owner}/#{repo}/milestones/#{milestone.number}"
    }
  end

  defp translate_error({msg, opts}) do
    Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
      to_string(Keyword.get(opts, String.to_existing_atom(key), key))
    end)
  end
end
