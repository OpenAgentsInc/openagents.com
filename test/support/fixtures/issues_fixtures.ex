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
  def issue_fixture(repository, attrs \\ %{}) do
    {:ok, issue} =
      OpenAgents.Issues.create_issue(repository, Enum.into(attrs, %{title: "some title"}))

    issue
  end
end
