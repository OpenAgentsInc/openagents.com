defmodule OpenAgents.ProjectFieldsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `OpenAgents.ProjectFields` context.
  """

  @doc """
  Generate a project_field.
  """
  def project_field_fixture(repository, attrs \\ %{}) do
    normalized = Map.new(attrs)
    project_id = Map.get(normalized, :project_id) || Map.get(normalized, "project_id")

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

    {:ok, project_field} =
      attrs
      |> Enum.into(%{
        data_type: "some data_type",
        name: "some name",
        options: %{},
        project_id: project.id
      })
      |> OpenAgents.ProjectFields.create_project_field()

    project_field
  end
end
