defmodule OpenAgents.RepositoriesMembershipTest do
  use OpenAgents.DataCase

  alias OpenAgents.Accounts
  alias OpenAgents.Labels
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Membership

  # A user with no automatic membership anywhere. `repository_user_fixture/1`
  # grants the initial repository, so tests that need an outsider build their
  # account here instead.
  defp plain_user(login) do
    github_id = System.unique_integer([:positive, :monotonic])

    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: login,
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    user
  end

  setup do
    repository = Repositories.initial_repository!()
    owner = plain_user("members-owner")
    {:ok, _membership} = Repositories.add_member(repository, owner, "owner")

    %{repository: repository, owner: owner}
  end

  test "list_members orders by role rank and then login", %{
    repository: repository,
    owner: _owner
  } do
    maintainer = plain_user("zebra-maintainer")
    viewer = plain_user("alpha-viewer")

    {:ok, _} = Repositories.add_member(repository, maintainer, "maintainer")
    {:ok, _} = Repositories.add_member(repository, viewer, "viewer")

    members = Repositories.list_members(repository)

    assert Enum.map(members, &{&1.user.github_login, &1.role}) == [
             {"members-owner", "owner"},
             {"zebra-maintainer", "maintainer"},
             {"alpha-viewer", "viewer"}
           ]
  end

  test "add_member_by_login grants a role to an existing active user", %{
    repository: repository,
    owner: owner
  } do
    newcomer = plain_user("newcomer")

    assert {:ok, %Membership{} = membership} =
             Repositories.add_member_by_login(
               repository,
               owner,
               String.upcase(newcomer.github_login),
               "contributor"
             )

    assert membership.role == "contributor"
    assert membership.user_id == newcomer.id
  end

  test "add_member_by_login rejects unknown users and invalid roles", %{
    repository: repository,
    owner: owner
  } do
    assert {:error, :unknown_user} =
             Repositories.add_member_by_login(repository, owner, "nobody-here", "contributor")

    assert_raise FunctionClauseError, fn ->
      Repositories.add_member_by_login(repository, owner, "anyone", "emperor")
    end
  end

  test "membership administration rejects a non-owner actor", %{
    repository: repository,
    owner: owner
  } do
    contributor = plain_user("membership-non-owner")
    recruit = plain_user("membership-recruit")
    {:ok, _} = Repositories.add_member(repository, contributor, "contributor")
    {:ok, _} = Repositories.add_member(repository, recruit, "viewer")

    assert {:error, :forbidden} =
             Repositories.add_member_by_login(
               repository,
               contributor,
               "membership-recruit",
               "maintainer"
             )

    assert {:error, :forbidden} =
             Repositories.change_member_role(repository, contributor, recruit.id, "maintainer")

    assert {:error, :forbidden} =
             Repositories.remove_member(repository, contributor, recruit.id)

    assert Repositories.membership_role(repository, recruit) == "viewer"
    assert Repositories.membership_role(repository, owner) == "owner"
  end

  test "change_member_role updates an existing membership", %{
    repository: repository,
    owner: owner
  } do
    member = plain_user("promoted")
    {:ok, _} = Repositories.add_member(repository, member, "contributor")

    assert {:ok, %Membership{role: "maintainer"}} =
             Repositories.change_member_role(repository, owner, member.id, "maintainer")
  end

  test "change_member_role refuses users who hold no membership", %{
    repository: repository,
    owner: owner
  } do
    stranger = plain_user("stranger-not-member")

    assert {:error, :unknown_member} =
             Repositories.change_member_role(repository, owner, stranger.id, "viewer")
  end

  test "the last owner cannot be demoted or removed", %{
    repository: repository,
    owner: owner
  } do
    assert {:error, :last_owner} =
             Repositories.change_member_role(repository, owner, owner.id, "maintainer")

    assert {:error, :last_owner} = Repositories.remove_member(repository, owner, owner.id)
  end

  test "an owner can be demoted while another owner remains", %{
    repository: repository,
    owner: owner
  } do
    second_owner = plain_user("second-owner")
    {:ok, _} = Repositories.add_member(repository, second_owner, "owner")

    assert {:ok, %Membership{role: "maintainer"}} =
             Repositories.change_member_role(repository, second_owner, owner.id, "maintainer")
  end

  test "remove_member deletes the membership row", %{repository: repository, owner: owner} do
    member = plain_user("departing")
    {:ok, _} = Repositories.add_member(repository, member, "contributor")

    assert :ok = Repositories.remove_member(repository, owner, member.id)
    refute Repositories.member?(repository, member)
  end

  test "member?, public?, and issue_participant? follow the participation model", %{
    repository: repository
  } do
    viewer_only = plain_user("viewer-only")
    {:ok, _} = Repositories.add_member(repository, viewer_only, "viewer")
    outsider = plain_user("outsider")

    assert Repositories.member?(repository, viewer_only)
    assert Repositories.issue_participant?(repository, viewer_only)

    # A public repository admits any signed-in person to the conversation.
    assert Repositories.public?(repository)
    assert Repositories.issue_participant?(repository, outsider)
    refute Repositories.issue_participant?(repository, nil)

    {:ok, private} =
      Repositories.create_repository(%{
        owner: "SecondOrg",
        name: "private-participation",
        visibility: "private"
      })

    refute Repositories.public?(private)
    refute Repositories.issue_participant?(private, outsider)

    {:ok, _} = Repositories.add_member(private, viewer_only, "viewer")
    assert Repositories.issue_participant?(private, viewer_only)
    refute Repositories.member?(private, outsider)
  end

  test "seed_default_labels! is idempotent", %{repository: repository} do
    assert :ok = Repositories.seed_default_labels!(repository)
    before = Labels.list_labels(repository)
    assert :ok = Repositories.seed_default_labels!(repository)

    names = Enum.map(before, & &1.name)
    assert "bug" in names
    assert "good first issue" in names
    assert length(before) == length(Labels.list_labels(repository))
  end

  test "creating a repository through the product path seeds default labels" do
    user = plain_user("seeder")

    {:ok, repository, _receipt} =
      Repositories.create_user_repository(
        user,
        %{
          name: "seeded-labels-repo",
          visibility: "public",
          default_branch: "main"
        },
        "seed-labels-key-#{System.unique_integer()}"
      )

    names = repository |> Labels.list_labels() |> Enum.map(& &1.name)
    assert "bug" in names
    assert "enhancement" in names
    assert "wontfix" in names
  end
end
