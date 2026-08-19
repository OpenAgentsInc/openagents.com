defmodule OpenAgents.ProjectFieldsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `OpenAgents.ProjectFields` context.
  """

  @doc """
  Generate a project_field.
  """
  def project_field_fixture(attrs \\ %{}) do
    {:ok, project} =
      OpenAgents.Projects.create_project(%{title: "Fixture project", owner: "OpenAgents"})

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
