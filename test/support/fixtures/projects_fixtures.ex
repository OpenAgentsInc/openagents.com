defmodule OpenAgents.ProjectsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `OpenAgents.Projects` context.
  """

  @doc """
  Generate a project.
  """
  def project_fixture(repository, attrs \\ %{}) do
    {:ok, project} =
      OpenAgents.Projects.create_project(
        repository,
        Enum.into(attrs, %{
          owner: "some owner",
          state: "open",
          title: "some title"
        })
      )

    project
  end
end
