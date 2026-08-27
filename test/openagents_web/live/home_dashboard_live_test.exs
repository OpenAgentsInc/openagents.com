defmodule OpenAgentsWeb.HomeDashboardLiveTest do
  @moduledoc """
  The signed-in homepage (#128, superseding #26).

  What matters here is that the dashboard describes the viewer's own work
  across every repository they can read rather than one repository picked for
  them, that its counts agree with `/issues` and `/projects` because they are
  read the same way, that a repository the viewer cannot read is absent from
  both the rows and the numbers, and that each kind of emptiness explains
  itself.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias OpenAgents.Issues
  alias OpenAgents.Projects
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Membership
  alias OpenAgents.Repositories.Repository

  setup %{conn: conn} do
    owner = github_user("home-dashboard-owner")

    # Private with a membership, so the same seeding proves both halves: the
    # owner reads across both repositories, and a stranger reads neither.
    first = ready_repository!(owner, "first-repository", "private")
    second = ready_repository!(owner, "second-repository", "private")

    {:ok, alpha} = Issues.create_issue(first, %{"title" => "Alpha needs a decision"}, owner)
    {:ok, beta} = Issues.create_issue(second, %{"title" => "Beta needs a decision"}, owner)

    board = project!(second, owner, "Second quarter board")

    %{
      conn: Plug.Test.init_test_session(conn, %{"user_id" => owner.id}),
      owner: owner,
      first: first,
      second: second,
      alpha: alpha,
      beta: beta,
      board: board
    }
  end

  test "the feed carries issues from every repository you can read", context do
    {:ok, view, html} = live(context.conn, ~p"/")

    assert html =~ "Alpha needs a decision"
    assert html =~ "Beta needs a decision"

    # Each row navigates to that issue in its own repository, and names it,
    # because a cross-repository feed is unreadable without the repository.
    assert issue_linked?(view, context.first, context.alpha)
    assert issue_linked?(view, context.second, context.beta)
    assert html =~ "#{context.first.owner}/#{context.first.name}"
  end

  test "the issue counts are the ones /issues shows the same viewer", context do
    {:ok, closable} = Issues.create_issue(context.first, %{"title" => "Already done"})
    {:ok, _closed} = Issues.update_issue(closable, %{"state" => "closed"}, context.owner)

    {:ok, home, _html} = live(context.conn, ~p"/")

    open = integer_at(home, "#dashboard-open-issue-count")
    closed = integer_at(home, "#dashboard-closed-issue-count")

    assert open == 2
    assert closed == 1

    {:ok, workspace, _html} = live(context.conn, ~p"/issues")

    assert has_element?(workspace, ~s{a[href="/issues?state=open"]}, "#{open} Open")
    assert has_element?(workspace, ~s{a[href="/issues?state=closed"]}, "#{closed} Closed")
  end

  test "the project panel and its count are the ones /projects shows", context do
    {:ok, view, html} = live(context.conn, ~p"/")

    assert html =~ "Second quarter board"

    assert has_element?(
             view,
             ~s{a[href="/#{context.second.owner}/#{context.second.name}/projects/#{context.board.number}"]}
           )

    open = integer_at(view, "#dashboard-open-project-count")
    assert open == 1

    {:ok, workspace, _html} = live(context.conn, ~p"/projects")
    assert has_element?(workspace, ~s{a[href="/projects?state=open"]}, "#{open} Open")
  end

  test "the panels point at the workspace lists, not at one repository", context do
    {:ok, view, _html} = live(context.conn, ~p"/")

    assert has_element?(view, ~s{a[href="/issues"]}, "View all")
    assert has_element?(view, ~s{a[href="/projects"]}, "View all")

    refute has_element?(
             view,
             ~s{a[href="/#{context.first.owner}/#{context.first.name}/issues"]}
           )
  end

  test "a stranger sees neither the rows nor the counts of a repository they cannot read",
       context do
    stranger = github_user("home-dashboard-stranger")
    conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => stranger.id})

    {:ok, view, html} = live(conn, ~p"/")

    refute html =~ "Alpha needs a decision"
    refute html =~ "Beta needs a decision"
    refute html =~ "Second quarter board"
    refute issue_linked?(view, context.first, context.alpha)
    refute issue_linked?(view, context.second, context.beta)

    assert integer_at(view, "#dashboard-open-issue-count") ==
             Issues.count_visible_issues(stranger, state: "open")

    assert integer_at(view, "#dashboard-open-issue-count") <
             Issues.count_visible_issues(context.owner, state: "open")

    assert integer_at(view, "#dashboard-open-project-count") ==
             Projects.count_visible_projects(stranger, state: "open")
  end

  test "a viewer with readable repositories and no issues is told exactly that", %{} do
    stranger = github_user("home-dashboard-quiet")
    conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => stranger.id})

    {:ok, view, html} = live(conn, ~p"/")

    assert integer_at(view, "#dashboard-open-issue-count") == 0
    assert html =~ "No open issues in the repositories you can read."
    assert html =~ "No open projects in the repositories you can read."
    refute html =~ "Import your first repository"
  end

  test "a viewer who can read no repository is told that instead", %{} do
    stranger = github_user("home-dashboard-repoless")

    Repo.delete_all(from membership in Membership, where: membership.user_id == ^stranger.id)
    Repo.update_all(Repository, set: [visibility: "private"])

    conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => stranger.id})
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "No repositories yet."
    assert html =~ "Import your first repository to start tracking issues."
    refute html =~ "No open issues in the repositories you can read."
  end

  defp integer_at(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
    |> String.to_integer()
  end

  defp issue_linked?(view, repository, issue) do
    has_element?(
      view,
      ~s{a[href="/#{repository.owner}/#{repository.name}/issues/#{issue.number}"]}
    )
  end

  defp project!(repository, owner, title) do
    {:ok, project} =
      Projects.create_project(
        repository,
        %{title: title, owner: owner.github_login, state: "open"},
        owner
      )

    project
  end

  defp ready_repository!(owner, name, visibility) do
    {:ok, repository, :created} =
      Repositories.create_user_repository(
        owner,
        %{name: name, visibility: visibility},
        "#{name}-key"
      )

    repository
    |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
    |> Repo.update!()
  end
end
