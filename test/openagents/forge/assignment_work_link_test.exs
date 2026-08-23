defmodule OpenAgents.Forge.AssignmentWorkLinkTest do
  @moduledoc """
  The read-only issue-to-job linkage from `#10`.

  An issue is the requested outcome. An assignment is one bound execution
  attempt against it. A work job is the execution. These tests hold the line
  between the three: reading attempts never creates a record, an issue with no
  attempt reads as an empty list rather than an absent fact, and the
  projection carries only what the attempt already publishes on the issue.
  """
  use OpenAgents.DataCase, async: true

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Conversations
  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Forge.Assignments
  alias OpenAgents.Issues
  alias OpenAgents.Machines
  alias OpenAgents.Repo
  alias OpenAgents.Work

  setup do
    user = repository_user_fixture("attempt-reader")
    repository = repository_with_member_fixture(user, %{}, "owner")
    {:ok, issue} = Issues.create_issue(repository, %{title: "Do the work"})
    %{user: user, repository: repository, issue: issue}
  end

  test "an issue nobody has worked reads as an empty list", %{issue: issue} do
    assert Assignments.attempts_for_issue(issue) == []
  end

  test "a page of issues always names every issue it was asked about", %{
    repository: repository,
    issue: issue
  } do
    {:ok, other} = Issues.create_issue(repository, %{title: "Untouched"})

    attempts = Assignments.attempts_for_issues([issue, other])

    assert attempts |> Map.keys() |> Enum.sort() == Enum.sort([issue.id, other.id])
    assert attempts[issue.id] == []
    assert attempts[other.id] == []
  end

  test "every recorded attempt reads back, oldest first", context do
    first = attempt(context, branch: "agent/first", offset: -600, state: "failed")
    second = attempt(context, branch: "agent/second", offset: -60)

    assert [%{branch: "agent/first"} = older, %{branch: "agent/second"} = newer] =
             Assignments.attempts_for_issue(context.issue)

    assert older.id == first.id
    assert newer.id == second.id
  end

  test "a terminal attempt keeps its exact commit and result", context do
    sha = String.duplicate("ab", 20)

    context
    |> attempt(branch: "agent/landed", offset: -300)
    |> Assignment.changeset(%{
      state: "completed",
      terminal_commit: sha,
      finished_at: DateTime.utc_now()
    })
    |> Repo.update!()

    assert [summary] = Assignments.attempts_for_issue(context.issue)
    assert summary.state == "completed"
    assert summary.terminal_commit == sha
    assert summary.finished_at
  end

  test "the projection never carries the conversation, the target, or the job", context do
    _attempt = attempt(context, branch: "agent/private", offset: -30)

    assert [summary] = Assignments.attempts_for_issue(context.issue)

    for key <- [
          :conversation_id,
          :conversation_box_id,
          :machine_id,
          :work_job_id,
          :repository_id,
          :requesting_principal
        ] do
      refute Map.has_key?(summary, key), "#{key} must stay off the issue projection"
    end
  end

  test "attempts on another issue never leak into this one", context do
    {:ok, other} = Issues.create_issue(context.repository, %{title: "Different work"})

    _mine = attempt(context, branch: "agent/mine", offset: -120)
    _theirs = attempt(%{context | issue: other}, branch: "agent/theirs", offset: -110)

    assert [%{branch: "agent/mine"}] = Assignments.attempts_for_issue(context.issue)
    assert [%{branch: "agent/theirs"}] = Assignments.attempts_for_issue(other)
  end

  test "an attempt records the durable work job that executed it", context do
    job = work_job(context.user)

    linked =
      context
      |> attempt(branch: "agent/joined", offset: -20)
      |> Assignment.changeset(%{work_job_id: job.id})
      |> Repo.update!()

    assert linked.work_job_id == job.id

    # The join reads in both directions without a second work record.
    assert %Assignment{issue_id: issue_id} = Repo.get_by(Assignment, work_job_id: job.id)
    assert issue_id == context.issue.id
  end

  test "an attempt cannot name a work job that does not exist", context do
    assert {:error, changeset} =
             context
             |> attempt(branch: "agent/absent", offset: -10)
             |> Assignment.changeset(%{work_job_id: Ecto.UUID.generate()})
             |> Repo.update()

    assert %{work_job_id: ["does not exist"]} = errors_on(changeset)
  end

  defp attempt(%{user: user, repository: repository, issue: issue}, options) do
    branch = Keyword.fetch!(options, :branch)
    state = Keyword.get(options, :state, "running")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    admitted_at = DateTime.add(now, Keyword.fetch!(options, :offset), :second)
    finished_at = if state in Assignment.terminal_states(), do: admitted_at

    %Assignment{}
    |> Assignment.changeset(%{
      target_kind: "computer",
      machine_id: paired_machine(user, branch).id,
      repository_id: repository.id,
      issue_id: issue.id,
      requesting_principal: %{"type" => "user", "id" => user.id},
      branch: branch,
      state: state,
      admitted_at: admitted_at,
      started_at: admitted_at,
      finished_at: finished_at,
      deadline_at: DateTime.add(admitted_at, 3600, :second)
    })
    |> Repo.insert!()
  end

  defp paired_machine(user, name) do
    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => name,
        "tier" => "curated",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => []
      })

    {:ok, machine} = Machines.approve_pairing(user, code)
    machine
  end

  defp work_job(user) do
    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    {:ok, job} =
      Work.create_job(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        surface: "text",
        goal: "work the issue"
      })

    job
  end
end
