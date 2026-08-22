defmodule OpenAgentsWeb.ProjectWorkspaceLiveTest do
  @moduledoc """
  The global project list at `/projects`, held to the same rules as `/issues`:
  one meaning wherever you reach it from, the repository named on every row,
  no leakage across a private repository in either direction, and a bound.
  """
  use OpenAgentsWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias OpenAgents.Projects
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Membership
  alias OpenAgents.Repositories.Repository

  setup %{conn: conn} do
    member = github_user("workspace-projects-member")
    owner = github_user("workspace-projects-owner")

    private = ready_repository!(owner, "board-only", "private")
    {:ok, _membership} = Repositories.add_member(private, member, "contributor")

    {:ok, secret} = Projects.create_project(private, %{"title" => "Key rotation"}, owner)

    %{
      conn: Plug.Test.init_test_session(conn, %{"user_id" => member.id}),
      member: member,
      owner: owner,
      private: private,
      secret: secret
    }
  end

  test "lists projects from every repository you can read, naming each one", context do
    {:ok, view, html} = live(context.conn, ~p"/projects")

    assert html =~ "Key rotation"
    assert has_element?(view, "#workspace-projects")
    assert project_linked?(view, context.private, context.secret)
    assert html =~ "#{context.private.owner}/#{context.private.name}"
  end

  test "a stranger to a private repository never sees its projects", context do
    stranger = github_user("workspace-projects-stranger")
    conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => stranger.id})

    {:ok, view, html} = live(conn, ~p"/projects")

    refute html =~ "Key rotation"
    refute project_linked?(view, context.private, context.secret)
  end

  test "the open and closed tabs each carry their own count", context do
    {:ok, closable} =
      Projects.create_project(context.private, %{"title" => "Shipped"}, context.owner)

    {:ok, _closed} = Projects.update_project(closable, %{"state" => "closed"})

    {:ok, view, _html} = live(context.conn, ~p"/projects")

    assert has_element?(view, ~s{a[href="/projects?state=open"][aria-current]})
    refute render(view) =~ "Shipped"

    closed = render_patch(view, ~p"/projects?state=closed")

    assert closed =~ "Shipped"
    refute closed =~ "Key rotation"
  end

  test "the created-by filter shows only what you created", context do
    {:ok, _mine} =
      Projects.create_project(context.private, %{"title" => "Mine to run"}, context.member)

    {:ok, view, _html} = live(context.conn, ~p"/projects")

    created =
      view
      |> form("#workspace-project-filter-form", %{"involvement" => "created"})
      |> render_change()

    assert created =~ "Mine to run"
    refute created =~ "Key rotation"
  end

  test "a filter value the URL invents falls back to everyone", context do
    {:ok, _view, html} = live(context.conn, ~p"/projects?involvement=everything")

    assert html =~ "Key rotation"
  end

  test "repositories with no matching projects get an empty state that says so", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/projects?state=closed")

    assert has_element?(view, "#workspace-projects-empty")
    assert html =~ "No closed projects"
    refute has_element?(view, "#workspace-projects-no-repositories")
  end

  test "an account that can read no repository is told that instead", %{} do
    stranger = github_user("workspace-projects-repoless")

    Repo.delete_all(from membership in Membership, where: membership.user_id == ^stranger.id)
    Repo.update_all(Repository, set: [visibility: "private"])

    conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => stranger.id})
    {:ok, view, html} = live(conn, ~p"/projects")

    assert has_element?(view, "#workspace-projects-no-repositories")
    assert html =~ "No repositories yet"
    assert has_element?(view, ~s{a[href="/repositories/import/github"]})
    refute has_element?(view, "#workspace-projects-empty")
  end

  test "the list is bounded and pages rather than loading everything", context do
    bulk = for index <- 1..(Projects.per_page() + 3), do: bulk_title(index)

    for title <- bulk do
      {:ok, _project} =
        Projects.create_project(context.private, %{"title" => title}, context.owner)
    end

    newest = List.last(bulk)
    oldest = List.first(bulk)

    {:ok, view, html} = live(context.conn, ~p"/projects")

    assert html =~ "Showing #{Projects.per_page()} of #{length(bulk) + 1}"
    assert html =~ newest
    refute html =~ oldest
    assert has_element?(view, ~s{a[href="/projects?page=2&state=open"]}, "Next")

    second = render_patch(view, ~p"/projects?state=open&page=2")

    assert second =~ oldest
    refute second =~ newest
  end

  test "a signed-out visitor is sent home rather than shown the list", %{} do
    assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), ~p"/projects")
  end

  defp bulk_title(index), do: "Board #{String.pad_leading(to_string(index), 3, "0")}"

  defp project_linked?(view, repository, project) do
    has_element?(
      view,
      ~s{a[href="/#{repository.owner}/#{repository.name}/projects/#{project.number}"]}
    )
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
