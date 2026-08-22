defmodule OpenAgentsWeb.IssueWorkspaceLiveTest do
  @moduledoc """
  The global issue list at `/issues`.

  What matters here is that the page means the same thing wherever you reach
  it from, that it names the repository each row belongs to, that a private
  repository stays private in both directions, and that both kinds of
  emptiness explain themselves.
  """
  use OpenAgentsWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias OpenAgents.Issues
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Membership
  alias OpenAgents.Repositories.Repository

  setup %{conn: conn} do
    member = github_user("workspace-issues-member")
    owner = github_user("workspace-issues-owner")

    private = ready_repository!(owner, "member-only", "private")
    {:ok, _membership} = Repositories.add_member(private, member, "contributor")

    {:ok, secret} = Issues.create_issue(private, %{"title" => "Rotate the signing key"}, owner)

    %{
      conn: Plug.Test.init_test_session(conn, %{"user_id" => member.id}),
      member: member,
      owner: owner,
      private: private,
      secret: secret
    }
  end

  test "lists issues from every repository you can read, naming each one", context do
    {:ok, view, html} = live(context.conn, ~p"/issues")

    assert html =~ "Rotate the signing key"
    assert has_element?(view, "#workspace-issues")

    assert has_element?(
             view,
             ~s{a[href="/#{context.private.owner}/#{context.private.name}/issues/#{context.secret.number}"]},
             "Rotate the signing key"
           )

    # A cross-repository list is unreadable without the repository, so the row
    # carries it in the scan column rather than at the trailing edge.
    assert has_element?(
             view,
             ".issue-row__repository",
             "#{context.private.owner}/#{context.private.name}"
           )
  end

  test "a stranger to a private repository never sees its issues", context do
    stranger = github_user("workspace-issues-stranger")
    conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => stranger.id})

    {:ok, view, html} = live(conn, ~p"/issues")

    refute html =~ "Rotate the signing key"
    refute issue_linked?(view, context.private, context.secret)
  end

  test "a stranger cannot reach it through the search filter either", context do
    stranger = github_user("workspace-issues-searcher")
    conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => stranger.id})

    {:ok, view, html} = live(conn, ~p"/issues?q=Rotate+the+signing+key")

    # The search box echoes the needle, so the title alone is not the test:
    # what matters is that no row links to the issue.
    refute issue_linked?(view, context.private, context.secret)
    assert html =~ "Nothing matches that search"
  end

  test "the open and closed tabs each carry their own count", context do
    {:ok, closable} = Issues.create_issue(context.private, %{"title" => "Already done"})
    {:ok, _closed} = Issues.update_issue(closable, %{"state" => "closed"}, context.owner)

    {:ok, view, _html} = live(context.conn, ~p"/issues")

    assert has_element?(view, ~s{a[href="/issues?state=open"][aria-current]})
    assert render(view) =~ "Rotate the signing key"
    refute render(view) =~ "Already done"

    closed = render_patch(view, ~p"/issues?state=closed")

    assert closed =~ "Already done"
    refute closed =~ "Rotate the signing key"
  end

  test "the assigned filter shows only what is assigned to you", context do
    {:ok, _mine} =
      Issues.create_issue(
        context.private,
        %{"title" => "Mine to do", "assignees" => [context.member.github_login]}
      )

    {:ok, view, _html} = live(context.conn, ~p"/issues")

    assigned =
      view
      |> form("#workspace-issue-filter-form", %{"involvement" => "assigned", "q" => ""})
      |> render_change()

    assert assigned =~ "Mine to do"
    refute assigned =~ "Rotate the signing key"
  end

  test "the opened-by filter shows only what you opened", context do
    {:ok, _mine} =
      Issues.create_issue(context.private, %{"title" => "I filed this"}, context.member)

    {:ok, view, _html} = live(context.conn, ~p"/issues")

    created =
      view
      |> form("#workspace-issue-filter-form", %{"involvement" => "created", "q" => ""})
      |> render_change()

    assert created =~ "I filed this"
    refute created =~ "Rotate the signing key"
  end

  test "a filter value the URL invents falls back to everyone", context do
    {:ok, _view, html} = live(context.conn, ~p"/issues?involvement=everything")

    assert html =~ "Rotate the signing key"
  end

  test "repositories with no matching issues get an empty state that says so", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/issues?q=nothing-matches-this")

    assert has_element?(view, "#workspace-issues-empty")
    assert html =~ "No open issues"
    assert html =~ "Nothing matches that search"
    refute has_element?(view, "#workspace-issues-no-repositories")
  end

  test "an account that can read no repository is told that instead", %{} do
    stranger = github_user("workspace-issues-repoless")

    Repo.delete_all(from membership in Membership, where: membership.user_id == ^stranger.id)
    Repo.update_all(Repository, set: [visibility: "private"])

    conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => stranger.id})
    {:ok, view, html} = live(conn, ~p"/issues")

    assert has_element?(view, "#workspace-issues-no-repositories")
    assert html =~ "No repositories yet"
    assert has_element?(view, ~s{a[href="/repositories/new"]})
    refute has_element?(view, "#workspace-issues-empty")
  end

  test "the list is bounded and pages rather than loading everything", context do
    # Zero-padded, so "Bulk 001" is never a substring of "Bulk 010".
    bulk = for index <- 1..(Issues.per_page() + 3), do: bulk_title(index)

    for title <- bulk do
      {:ok, _issue} = Issues.create_issue(context.private, %{"title" => title})
    end

    newest = List.last(bulk)
    oldest = List.first(bulk)

    {:ok, view, html} = live(context.conn, ~p"/issues")

    assert html =~ "Showing #{Issues.per_page()} of #{length(bulk) + 1}"
    assert html =~ newest
    refute html =~ oldest
    assert has_element?(view, ~s{a[href="/issues?page=2&state=open"]}, "Next")

    second = render_patch(view, ~p"/issues?state=open&page=2")

    assert second =~ oldest
    refute second =~ newest
  end

  test "a signed-out visitor is sent home rather than shown the list", %{} do
    assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), ~p"/issues")
  end

  defp bulk_title(index), do: "Bulk #{String.pad_leading(to_string(index), 3, "0")}"

  defp issue_linked?(view, repository, issue) do
    has_element?(
      view,
      ~s{a[href="/#{repository.owner}/#{repository.name}/issues/#{issue.number}"]}
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
