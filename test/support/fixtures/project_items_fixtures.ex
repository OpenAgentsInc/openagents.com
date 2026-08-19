defmodule OpenAgents.ProjectItemsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `OpenAgents.ProjectItems` context.
  """

  @doc """
  Generate a project_item.
  """
  def project_item_fixture(attrs \\ %{}) do
    {:ok, project} =
      OpenAgents.Projects.create_project(%{title: "Fixture project", owner: "OpenAgents"})

    {:ok, issue} = OpenAgents.Issues.create_issue(%{title: "Fixture issue"})

    {:ok, project_item} =
      attrs
      |> Enum.into(%{
        values: %{},
        project_id: project.id,
        issue_id: issue.id
      })
      |> OpenAgents.ProjectItems.create_project_item()

    project_item
  end
end
