defmodule OpenAgents.LabelsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `OpenAgents.Labels` context.
  """

  @doc """
  Generate a label.
  """
  def label_fixture(repository, attrs \\ %{}) do
    {:ok, label} =
      OpenAgents.Labels.create_label(
        repository,
        Enum.into(attrs, %{
          color: "some color",
          description: "some description",
          name: "some name"
        })
      )

    label
  end
end
