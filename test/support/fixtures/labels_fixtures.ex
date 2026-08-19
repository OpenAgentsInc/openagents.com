defmodule OpenAgents.LabelsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `OpenAgents.Labels` context.
  """

  @doc """
  Generate a label.
  """
  def label_fixture(attrs \\ %{}) do
    {:ok, label} =
      attrs
      |> Enum.into(%{
        color: "some color",
        description: "some description",
        name: "some name"
      })
      |> OpenAgents.Labels.create_label()

    label
  end
end
