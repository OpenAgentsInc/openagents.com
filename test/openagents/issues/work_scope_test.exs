defmodule OpenAgents.Issues.WorkScopeTest do
  @moduledoc """
  `#10`: starting bounded agent work *from* an issue.

  The property under test is that the bound is the issue's, not the caller's.
  Two halves:

  **The scope is read from the issue.** The objective is written from the
  issue's own title and body, and the branch from its number, so two attempts
  on the same issue are asked the same question.

  **The limits are read from the issue, and a caller may only narrow them.** An
  issue that states every section `OUTCOME-001` requires buys the full hour; an
  issue that does not buys a short exploratory window, because a claim against
  it can never be accepted. `Assignments.create/1` is where that applies, so it
  applies to the issue page and to the API alike rather than to whichever
  surface remembered.
  """
  use OpenAgents.DataCase, async: true

  import Ecto.Query
  import OpenAgents.AccountsFixtures

  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Conversations
  alias OpenAgents.Forge.{Assignment, Assignments}
  alias OpenAgents.Issues
  alias OpenAgents.Issues.WorkScope
  alias OpenAgents.Repo

  @scoped_body """
  ## Problem

  Nothing bounds an attempt.

  ## Scope

  One module and its admission point.

  ## Acceptance criteria

  - The wall clock comes from the issue.

  ## Success metrics

  An unscoped issue cannot buy an hour.
  """

  setup do
    owner = repository_user_fixture("scope-owner")
    repository = repository_with_member_fixture(owner, %{visibility: "public"}, "owner")

    {:ok, scoped} =
      Issues.create_issue(repository, %{title: "Bound the work", body: @scoped_body})

    {:ok, unscoped} =
      Issues.create_issue(repository, %{title: "Do something", body: "Make it better."})

    %{owner: owner, repository: repository, scoped: scoped, unscoped: unscoped}
  end

  describe "the scope comes from the issue" do
    test "the objective names the issue, its title, and its one writable branch", context do
      objective = WorkScope.objective(context.scoped)

      assert objective =~ "issue ##{context.scoped.number}"
      assert objective =~ "Bound the work"
      assert objective =~ "Nothing bounds an attempt."
      assert objective =~ "agent/issue-#{context.scoped.number}"
    end

    test "the branch is derived from the issue number", context do
      assert WorkScope.branch(context.scoped) == "agent/issue-#{context.scoped.number}"
    end

    test "a long body is clamped on a character boundary, not refused", context do
      body = String.duplicate("é", 8_000)
      {:ok, long} = Issues.create_issue(context.repository, %{title: "Long", body: body})

      objective = WorkScope.objective(long)

      assert String.valid?(objective)
      assert byte_size(objective) < 8_000
    end
  end

  describe "the limits come from the issue's own scope" do
    test "an issue stating every required section buys the full hour", context do
      scope = WorkScope.for_issue(context.scoped)

      assert scope.scoped?
      assert scope.missing_sections == []
      assert scope.wall_clock_ms == WorkScope.scoped_wall_clock_ms()
    end

    test "an issue missing a section buys the exploratory window", context do
      scope = WorkScope.for_issue(context.unscoped)

      refute scope.scoped?
      assert scope.wall_clock_ms == WorkScope.unscoped_wall_clock_ms()
      assert scope.wall_clock_ms < WorkScope.scoped_wall_clock_ms()
    end

    test "the missing sections are named, in contract order", context do
      assert WorkScope.missing_sections(context.unscoped) ==
               [:problem, :scope, :acceptance_criteria, :success_metrics]
    end

    test "a body absent entirely states no section", context do
      {:ok, bodiless} = Issues.create_issue(context.repository, %{title: "No body"})

      refute WorkScope.scoped?(bodiless)
    end

    test "a heading with no content under it does not count as stated", context do
      {:ok, empty} =
        Issues.create_issue(context.repository, %{
          title: "Headings only",
          body: "## Problem\n\n## Scope\n\n## Acceptance criteria\n\n## Success metrics\n"
        })

      assert WorkScope.missing_sections(empty) ==
               [:problem, :scope, :acceptance_criteria, :success_metrics]
    end

    test "the reader is the grader's own parser, so the two cannot disagree", context do
      stated = OpenAgents.Issues.CompletionClaims.sections(context.scoped.body)

      for section <- OpenAgents.AcceptedOutcome.required_issue_sections() do
        assert Map.get(stated, section), "the grader does not see #{section}"
        refute section in WorkScope.missing_sections(context.scoped)
      end
    end
  end

  describe "the admission point applies the bound" do
    test "an unscoped issue's attempt gets the short deadline", context do
      assignment = admit(context, context.unscoped)

      assert within_ms?(assignment.deadline_at, WorkScope.unscoped_wall_clock_ms())
    end

    test "a scoped issue's attempt gets the full deadline", context do
      assignment = admit(context, context.scoped)

      assert within_ms?(assignment.deadline_at, WorkScope.scoped_wall_clock_ms())
    end

    test "a caller may narrow the bound", context do
      requested = DateTime.add(DateTime.utc_now(), 120, :second)
      assignment = admit(context, context.scoped, %{"deadline_at" => requested})

      assert DateTime.compare(assignment.deadline_at, requested) == :eq
    end

    test "a caller may not widen the bound", context do
      # Two hours, past both the issue's window and the deployment TTL.
      requested = DateTime.add(DateTime.utc_now(), 7_200, :second)
      assignment = admit(context, context.unscoped, %{"deadline_at" => requested})

      assert DateTime.compare(assignment.deadline_at, requested) == :lt
      assert within_ms?(assignment.deadline_at, WorkScope.unscoped_wall_clock_ms())
    end
  end

  # The run never starts in a test, and it does not need to: the assignment is
  # committed by `persist_assignment/7` before `start_target/7` is reached, so
  # the row this reads is the row the production path writes.
  defp admit(context, issue, extra \\ %{}) do
    {:ok, conversation} = Conversations.ensure_conversation(context.owner)

    {:ok, box} =
      %ConversationBox{}
      |> ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_scope_#{System.unique_integer([:positive])}",
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert()

    attrs =
      Map.merge(
        %{
          "target_kind" => "box",
          "box_id" => box.box_id,
          "conversation_id" => conversation.id,
          "repository_id" => context.repository.id,
          "issue_number" => issue.number,
          "branch" => WorkScope.branch(issue),
          "requesting_user" => context.owner,
          "requesting_principal" => context.owner
        },
        extra
      )

    result = try_create(attrs)

    case Repo.one(from a in Assignment, where: a.issue_id == ^issue.id, limit: 1) do
      nil -> flunk("no assignment persisted: #{inspect(result)}")
      row -> row
    end
  end

  defp try_create(attrs) do
    Assignments.create(attrs)
  rescue
    error -> {:error, error}
  end

  # The deadline is stamped at admission, so it lands within a second of
  # `now + bound`. Asserting a window rather than an instant keeps the test
  # about the bound rather than about the clock.
  defp within_ms?(deadline, bound) do
    actual = DateTime.diff(deadline, DateTime.utc_now(), :millisecond)
    actual > bound - 5_000 and actual <= bound
  end
end
