defmodule OpenAgents.IssuesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `OpenAgents.Issues` context.
  """

  @doc """
  Generate an issue.

  The issue number is assigned by the context, so callers get a fresh,
  monotonically increasing number without having to coordinate.
  """
  def issue_fixture(attrs \\ %{}) do
    {:ok, issue} =
      attrs
      |> Enum.into(%{title: "some title"})
      |> OpenAgents.Issues.create_issue()

    issue
  end
end
