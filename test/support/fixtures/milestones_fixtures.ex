defmodule OpenAgents.MilestonesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `OpenAgents.Milestones` context.
  """

  @doc """
  Generate a milestone.
  """
  def milestone_fixture(repository, attrs \\ %{}) do
    {:ok, milestone} =
      OpenAgents.Milestones.create_milestone(
        repository,
        Enum.into(attrs, %{
          description: "some description",
          due_on: "some due_on",
          number: 42,
          state: "some state",
          title: "some title"
        })
      )

    milestone
  end
end
