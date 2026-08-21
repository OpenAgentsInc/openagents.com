defmodule OpenAgents.RepositoriesTest do
  use OpenAgents.DataCase

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Comment
  alias OpenAgents.Labels
  alias OpenAgents.Milestones
  alias OpenAgents.ProjectItems.ProjectItem
  alias OpenAgents.Projects
  alias OpenAgents.Repositories

  setup do
    initial = Repositories.initial_repository!()

    {:ok, second} =
      Repositories.create_repository(%{
        owner: "SecondOrg",
        name: "second-repo",
        visibility: "private",
        default_branch: "trunk"
      })

    user = repository_user_fixture("tenant-member")
    {:ok, _membership} = Repositories.add_member(second, user, "maintainer")

    %{initial: initial, second: second, user: user}
  end

  test "the explicit initial repository has a stable canonical identity", %{initial: initial} do
    assert initial.id == "00000000-0000-4000-8000-000000000001"
    assert initial.owner == "OpenAgentsInc"
    assert initial.name == "openagents.com"
    assert initial.visibility == "public"
    assert initial.default_branch == "main"

    assert Repositories.get_by_path!("openagentsinc", "OPENAGENTS.COM").id == initial.id
  end

  test "issue and milestone numbers are allocated independently per repository", %{
    initial: initial,
    second: second
  } do
    assert {:ok, initial_issue} = Issues.create_issue(initial, %{title: "Initial"})
    assert {:ok, second_issue} = Issues.create_issue(second, %{title: "Second"})
    assert initial_issue.number == 1
    assert second_issue.number == 1

    assert {:ok, initial_milestone} = Milestones.create_milestone(initial, %{title: "Initial"})
    assert {:ok, second_milestone} = Milestones.create_milestone(second, %{title: "Second"})
    assert initial_milestone.number == 1
    assert second_milestone.number == 1
  end

  test "public paths cannot cross repository ownership or expose a private repository", %{
    initial: initial,
    second: second
  } do
    assert {:ok, initial_issue} = Issues.create_issue(initial, %{title: "Initial"})
    assert {:ok, second_issue} = Issues.create_issue(second, %{title: "Second"})

    assert Issues.get_issue_by_path!("OpenAgentsInc", "openagents.com", 1).id ==
             initial_issue.id

    assert Issues.get_issue_by_number!(second, 1).id == second_issue.id

    assert_raise Ecto.NoResultsError, fn ->
      Issues.get_issue_by_path!("SecondOrg", "second-repo", 1)
    end
  end

  test "labels and milestones from another repository are rejected", %{
    initial: initial,
    second: second
  } do
    assert {:ok, issue} = Issues.create_issue(initial, %{title: "Scoped"})
    assert {:ok, second_label} = Labels.create_label(second, %{name: "private", color: "ffffff"})
    assert {:ok, milestone} = Milestones.create_milestone(second, %{title: "Second"})

    # Adding a name that exists only in the other repository creates a fresh,
    # locally-scoped label; it never links across the repository boundary.
    assert {:ok, labelled} = Issues.add_labels(issue, ["private"])
    assert [%{"name" => "private"}] = labelled.labels

    local_label = Labels.get_label_by_name!(initial, "private")
    refute local_label.id == second_label.id

    # The milestone lookup stays strict: a number from another repository
    # cannot be attached at all.
    assert_raise Ecto.NoResultsError, fn ->
      Issues.set_milestone(issue, milestone.number)
    end

    assert Enum.map(Labels.list_labels(second), & &1.name) == ["private"]
  end

  test "only active repository members are assignable", %{initial: initial, second: second} do
    _initial_only = repository_user_fixture("initial-only")

    assert Enum.map(Repositories.list_assignable_users(initial), & &1.github_login) == [
             "initial-only",
             "tenant-member"
           ]

    assert Enum.map(Repositories.list_assignable_users(second), & &1.github_login) == [
             "tenant-member"
           ]

    assert_raise Ecto.NoResultsError, fn ->
      Repositories.get_assignable_user_by_login!(second, "initial-only")
    end
  end

  test "a banned membership is neither writable nor assignable", %{second: second, user: user} do
    assert {:ok, banned} = OpenAgents.Accounts.ban_user(user, "repository_policy")
    refute Repositories.writable?(second, banned)
    assert Repositories.list_assignable_users(second) == []

    assert_raise Ecto.NoResultsError, fn ->
      Repositories.get_writable_by_path!(second.owner, second.name, banned)
    end
  end

  test "project-item and comment constraints reject cross-repository parents", %{
    initial: initial,
    second: second,
    user: user
  } do
    assert {:ok, project} = Projects.create_project(initial, %{title: "Initial"}, user)
    assert {:ok, second_issue} = Issues.create_issue(second, %{title: "Second"})

    assert {:error, item_changeset} =
             %ProjectItem{}
             |> ProjectItem.changeset(%{
               project_id: project.id,
               issue_id: second_issue.id,
               repository_id: initial.id
             })
             |> Repo.insert()

    assert %{issue_id: ["does not exist"]} = errors_on(item_changeset)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:error, comment_changeset} =
             %Comment{}
             |> Comment.changeset(%{
               issue_id: second_issue.id,
               repository_id: initial.id,
               body: "cross tenant",
               created_at: now,
               updated_at: now
             })
             |> Repo.insert()

    assert %{issue_id: ["does not exist"]} = errors_on(comment_changeset)
  end

  test "project paths require both the repository and project number", %{
    initial: initial,
    second: second,
    user: user
  } do
    assert {:ok, initial_project} = Projects.create_project(initial, %{title: "Initial"}, user)
    assert {:ok, second_project} = Projects.create_project(second, %{title: "Second"}, user)

    assert initial_project.number == second_project.number

    assert Projects.get_project_by_path!("OpenAgentsInc", "openagents.com", 1).id ==
             initial_project.id

    assert Projects.get_project_by_number!(second, 1).id == second_project.id

    assert_raise Ecto.NoResultsError, fn ->
      Projects.get_project_by_path!("SecondOrg", "second-repo", 1)
    end
  end
end
