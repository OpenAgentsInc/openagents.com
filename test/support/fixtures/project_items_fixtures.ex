defmodule OpenAgents.ProjectItemsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `OpenAgents.ProjectItems` context.
  """

  @doc """
  Generate a project_item.
  """
  def project_item_fixture(repository, attrs \\ %{}) do
    normalized = Map.new(attrs)
    project_id = Map.get(normalized, :project_id) || Map.get(normalized, "project_id")
    issue_id = Map.get(normalized, :issue_id) || Map.get(normalized, "issue_id")

    project =
      if project_id do
        OpenAgents.Projects.get_project!(repository, project_id)
      else
        {:ok, project} =
          OpenAgents.Projects.create_project(repository, %{
            title: "Fixture project",
            owner: "OpenAgents"
          })

        project
      end

    issue =
      if issue_id do
        OpenAgents.Issues.get_issue!(repository, issue_id)
      else
        {:ok, issue} = OpenAgents.Issues.create_issue(repository, %{title: "Fixture issue"})
        issue
      end

    {:ok, project_item} =
      attrs
      |> Enum.into(%{
        values: %{},
        project_id: project.id,
        issue_id: issue.id
      })
      |> then(&OpenAgents.ProjectItems.create_project_item(repository, &1))

    project_item
  end
end
