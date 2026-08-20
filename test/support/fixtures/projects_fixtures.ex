defmodule OpenAgents.ProjectsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `OpenAgents.Projects` context.
  """

  @doc """
  Generate a project.
  """
  def project_fixture(attrs \\ %{}) do
    {:ok, project} =
      attrs
      |> Enum.into(%{
        owner: "some owner",
        state: "some state",
        title: "some title"
      })
      |> OpenAgents.Projects.create_project()

    project
  end
end
