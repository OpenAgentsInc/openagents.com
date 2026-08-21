defmodule OpenAgentsWeb.MemberIndexLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import OpenAgents.AccountsFixtures

  alias OpenAgents.Repositories

  defp plain_user(login) do
    github_id = System.unique_integer([:positive, :monotonic])

    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: login,
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    user
  end

  defp sign_in_owner(conn, key) do
    user = repository_user_fixture(key)
    {:ok, _} = Repositories.add_member(Repositories.initial_repository!(), user, "owner")
    {Plug.Test.init_test_session(conn, %{"user_id" => user.id}), user}
  end

  test "an owner sees the members and their roles", %{conn: conn} do
    {conn, _owner} = sign_in_owner(conn, "members-view-owner")
    repository_user_fixture("members-view-member")

    {:ok, _view, html} = live(conn, ~p"/OpenAgentsInc/openagents.com/members")

    assert html =~ "members-view-owner"
    assert html =~ "members-view-member"
    assert html =~ String.capitalize("contributor")
  end

  test "an owner adds a member by GitHub login", %{conn: conn} do
    {conn, _owner} = sign_in_owner(conn, "members-add-owner")
    recruit = plain_user("recruit")

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/members")

    view
    |> form("#add-member-form", member: %{login: "recruit", role: "maintainer"})
    |> render_submit()

    html = render(view)
    assert has_element?(view, "#members")
    assert html =~ "recruit"

    assert Repositories.membership_role(Repositories.initial_repository!(), recruit) ==
             "maintainer"
  end

  test "adding an unknown login explains what to do", %{conn: conn} do
    {conn, _owner} = sign_in_owner(conn, "members-unknown-owner")

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/members")

    html =
      view
      |> form("#add-member-form", member: %{login: "never-signed-in", role: "viewer"})
      |> render_submit()

    assert html =~ "need to sign in once"
  end

  test "an owner changes a member's role", %{conn: conn} do
    {conn, _owner} = sign_in_owner(conn, "members-role-owner")
    member = repository_user_fixture("role-target")

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/members")

    view
    |> form("#member-role-form-member-#{member.id}", %{
      "user_id" => member.id,
      "role" => "maintainer"
    })
    |> render_change()

    assert Repositories.membership_role(Repositories.initial_repository!(), member) ==
             "maintainer"
  end

  test "an owner removes a member", %{conn: conn} do
    {conn, _owner} = sign_in_owner(conn, "members-remove-owner")
    member = repository_user_fixture("remove-target")
    repository = Repositories.initial_repository!()

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/members")

    view
    |> element(~s{button[phx-click="remove_member"][phx-value-user-id="#{member.id}"]})
    |> render_click()

    refute Repositories.member?(repository, member)
  end

  test "a demoted owner cannot keep administering through an open page", %{conn: conn} do
    {conn, owner} = sign_in_owner(conn, "members-stale-owner")
    recruit = plain_user("members-stale-recruit")
    repository = Repositories.initial_repository!()

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/members")
    {:ok, _} = Repositories.add_member(repository, owner, "contributor")

    html =
      view
      |> form("#add-member-form", member: %{login: recruit.github_login, role: "viewer"})
      |> render_submit()

    assert html =~ "Only repository owners can manage members"
    refute Repositories.member?(repository, recruit)
  end

  test "the last owner cannot be removed through the page", %{conn: conn} do
    {conn, owner} = sign_in_owner(conn, "members-last-owner")

    {:ok, view, _html} = live(conn, ~p"/OpenAgentsInc/openagents.com/members")

    html =
      view
      |> element(~s{button[phx-click="remove_member"][phx-value-user-id="#{owner.id}"]})
      |> render_click()

    assert html =~ "at least one owner"
    assert Repositories.member?(Repositories.initial_repository!(), owner)
  end

  test "a non-owner is sent away", %{conn: conn} do
    conn = log_in_github_user(conn, "plain-contributor")

    {:error, {:redirect, %{to: to}}} = live(conn, ~p"/OpenAgentsInc/openagents.com/members")

    assert to == "/OpenAgentsInc/openagents.com/issues"
  end
end
