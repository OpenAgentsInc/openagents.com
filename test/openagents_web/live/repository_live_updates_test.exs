defmodule OpenAgentsWeb.RepositoryLiveUpdatesTest do
  @moduledoc """
  The repository-scoped surfaces as live surfaces (#159, following #154).

  `#154` fixed the signed-in homepage and audited the rest. Three pages here
  subscribed but re-read only part of what they had loaded; five more had a
  publisher nobody had subscribed to. Both shapes render the same defect: a
  number that stopped being true while you were looking at it.

  Every surface below re-reads through the authorization it mounted under, and
  proves it in both directions -- a write moves the page, and a viewer whose
  write access is withdrawn loses what it was giving them. The counts
  stay aggregates: the assignee and milestone indexes now group in Postgres
  rather than loading every issue in the repository to count it in memory.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Ecto.Query
  import OpenAgents.AccountsFixtures
  import Phoenix.LiveViewTest

  alias OpenAgents.Issues
  alias OpenAgents.Labels
  alias OpenAgents.Milestones
  alias OpenAgents.Projects
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Membership

  setup %{conn: conn} do
    member = github_user("repo-live-member")
    repository = repository_with_member_fixture(member)

    %{
      conn: Plug.Test.init_test_session(conn, %{"user_id" => member.id}),
      member: member,
      repository: repository
    }
  end

  describe "the issue page" do
    test "a label created elsewhere joins the picker", context do
      {:ok, issue} =
        Issues.create_issue(context.repository, %{"title" => "Needs a label"}, context.member)

      {:ok, view, _html} = live(context.conn, issue_path(context.repository, issue))

      refute render(view) =~ "needs-triage"

      {:ok, _label} =
        Labels.create_label(context.repository, %{"name" => "needs-triage", "color" => "ededed"})

      # The label write does not announce itself, so this is the issue topic
      # doing the work: any write to the repository's issues re-reads
      # everything the page derived from the repository, not only the issue.
      Repositories.broadcast_issues(context.repository.id)

      assert render(view) =~ "needs-triage"
    end

    test "a milestone created elsewhere joins the picker", context do
      {:ok, issue} =
        Issues.create_issue(context.repository, %{"title" => "Needs a milestone"}, context.member)

      {:ok, view, _html} = live(context.conn, issue_path(context.repository, issue))

      refute render(view) =~ "Second quarter"

      {:ok, _milestone} =
        Milestones.create_milestone(
          context.repository,
          %{"title" => "Second quarter"},
          context.member
        )

      Repositories.broadcast_issues(context.repository.id)

      assert render(view) =~ "Second quarter"
    end

    test "write access withdrawn elsewhere takes the pickers with it", context do
      {:ok, _label} =
        Labels.create_label(context.repository, %{"name" => "needs-triage", "color" => "ededed"})

      {:ok, issue} =
        Issues.create_issue(
          context.repository,
          %{"title" => "Written while a member"},
          context.member
        )

      {:ok, view, _html} = live(context.conn, issue_path(context.repository, issue))

      assert render(view) =~ "needs-triage"

      revoke_write_access!(context.repository, context.member)
      Repositories.broadcast_issues(context.repository.id)

      # The pickers are read beside the authority that decides whether to offer
      # them, so they cannot disagree: no write access, nothing offered.
      refute render(view) =~ "needs-triage"
    end
  end

  describe "the project board" do
    test "an issue opened elsewhere joins the item picker", context do
      {:ok, project} =
        Projects.create_project(
          context.repository,
          %{title: "Delivery", owner: context.member.github_login, state: "open"},
          context.member
        )

      {:ok, view, _html} = live(context.conn, project_path(context.repository, project))

      refute render(view) =~ "Opened in another tab"

      {:ok, _issue} =
        Issues.create_issue(
          context.repository,
          %{"title" => "Opened in another tab"},
          context.member
        )

      assert render(view) =~ "Opened in another tab"
    end

    test "write access withdrawn elsewhere retires the composer", context do
      {:ok, project} =
        Projects.create_project(
          context.repository,
          %{title: "Delivery", owner: context.member.github_login, state: "open"},
          context.member
        )

      {:ok, view, _html} = live(context.conn, project_path(context.repository, project))

      assert has_element?(view, "#new-project-item-form")

      revoke_write_access!(context.repository, context.member)

      # A change message, not an action taken on the page: authority is
      # re-read on the same beat as the board rather than only when the viewer
      # tries something.
      Repositories.broadcast_projects(context.repository.id)

      refute has_element?(view, "#new-project-item-form")
    end
  end

  describe "the project list" do
    test "a project opened elsewhere joins the list", context do
      {:ok, view, _html} =
        live(context.conn, ~p"/#{context.repository.owner}/#{context.repository.name}/projects")

      refute render(view) =~ "Second quarter board"

      {:ok, _project} =
        Projects.create_project(
          context.repository,
          %{title: "Second quarter board", owner: context.member.github_login, state: "open"},
          context.member
        )

      assert render(view) =~ "Second quarter board"
    end
  end

  describe "the milestone list" do
    test "closing an issue elsewhere moves the milestone's counts", context do
      {:ok, milestone} =
        Milestones.create_milestone(context.repository, %{"title" => "v1"}, context.member)

      {:ok, issue} =
        Issues.create_issue(
          context.repository,
          %{"title" => "In the milestone", "milestone" => milestone.number},
          context.member
        )

      {:ok, view, _html} =
        live(context.conn, ~p"/#{context.repository.owner}/#{context.repository.name}/milestones")

      assert has_element?(view, "#milestone-#{milestone.number}", "1 open")
      assert has_element?(view, "#milestone-#{milestone.number}", "0 closed")

      {:ok, _closed} = Issues.update_issue(issue, %{"state" => "closed"}, context.member)

      assert has_element?(view, "#milestone-#{milestone.number}", "0 open")
      assert has_element?(view, "#milestone-#{milestone.number}", "1 closed")
    end

    test "the counts are grouped aggregates, not a collection loaded to measure",
         context do
      {:ok, milestone} =
        Milestones.create_milestone(context.repository, %{"title" => "v1"}, context.member)

      for index <- 1..3 do
        {:ok, _issue} =
          Issues.create_issue(
            context.repository,
            %{"title" => "Issue #{index}", "milestone" => milestone.number},
            context.member
          )
      end

      {:ok, view, _html} =
        live(context.conn, ~p"/#{context.repository.owner}/#{context.repository.name}/milestones")

      sql =
        capture_queries(view.pid, fn ->
          Repositories.broadcast_issues(context.repository.id)
          render(view)
        end)

      issue_reads = Enum.filter(sql, &String.contains?(&1, ~s(FROM "issues")))

      assert issue_reads != []
      assert Enum.all?(issue_reads, &String.contains?(&1, "count("))
    end
  end

  describe "the assignee list" do
    test "an assignment made elsewhere moves the count", context do
      {:ok, issue} =
        Issues.create_issue(context.repository, %{"title" => "Unassigned"}, context.member)

      {:ok, view, _html} =
        live(context.conn, ~p"/#{context.repository.owner}/#{context.repository.name}/assignees")

      refute has_element?(view, "#assignees")

      {:ok, _assigned} =
        Issues.add_assignees(issue, [context.member.github_login], context.member)

      assert has_element?(view, "#assignees", context.member.github_login)
    end

    test "write access withdrawn elsewhere empties the list", context do
      {:ok, issue} =
        Issues.create_issue(context.repository, %{"title" => "Assigned"}, context.member)

      {:ok, _assigned} =
        Issues.add_assignees(issue, [context.member.github_login], context.member)

      {:ok, view, _html} =
        live(context.conn, ~p"/#{context.repository.owner}/#{context.repository.name}/assignees")

      assert has_element?(view, "#assignees", context.member.github_login)

      revoke_write_access!(context.repository, context.member)
      Repositories.broadcast_issues(context.repository.id)

      refute has_element?(view, "#assignees")
    end

    test "the counts are grouped aggregates, not a collection loaded to measure",
         context do
      for index <- 1..3 do
        {:ok, issue} =
          Issues.create_issue(context.repository, %{"title" => "Issue #{index}"}, context.member)

        {:ok, _assigned} =
          Issues.add_assignees(issue, [context.member.github_login], context.member)
      end

      {:ok, view, _html} =
        live(context.conn, ~p"/#{context.repository.owner}/#{context.repository.name}/assignees")

      sql =
        capture_queries(view.pid, fn ->
          Repositories.broadcast_issues(context.repository.id)
          render(view)
        end)

      issue_reads = Enum.filter(sql, &String.contains?(&1, ~s(FROM "issues")))

      assert issue_reads != []
      assert Enum.all?(issue_reads, &String.contains?(&1, "count("))
    end
  end

  describe "the pull request pages" do
    test "an issue opened elsewhere moves the issue tab count", context do
      issue = pull_request_issue!(context.repository, context.member)

      {:ok, index, _html} =
        live(context.conn, ~p"/#{context.repository.owner}/#{context.repository.name}/pulls")

      {:ok, show, _html} =
        live(
          context.conn,
          ~p"/#{context.repository.owner}/#{context.repository.name}/pulls/#{issue.number}"
        )

      refute render(index) =~ "Nothing yet"

      {:ok, _issue} =
        Issues.create_issue(context.repository, %{"title" => "Nothing yet"}, context.member)

      # The tab badge only renders once the count is above zero, which is what
      # makes its arrival the assertion.
      assert has_element?(
               index,
               ~s{a[href="/#{context.repository.owner}/#{context.repository.name}/issues"]},
               "1"
             )

      assert has_element?(
               show,
               ~s{a[href="/#{context.repository.owner}/#{context.repository.name}/issues"]},
               "1"
             )
    end
  end

  describe "the repository home" do
    test "an issue opened elsewhere moves the issue tab count", context do
      {:ok, view, _html} =
        live(context.conn, ~p"/#{context.repository.owner}/#{context.repository.name}")

      {:ok, _issue} =
        Issues.create_issue(context.repository, %{"title" => "Nothing yet"}, context.member)

      assert has_element?(
               view,
               ~s{a[href="/#{context.repository.owner}/#{context.repository.name}/issues"]},
               "1"
             )
    end
  end

  describe "authorization" do
    test "a write in another repository moves nothing", context do
      other = repository_with_member_fixture(context.member)

      {:ok, view, _html} =
        live(context.conn, ~p"/#{context.repository.owner}/#{context.repository.name}/milestones")

      {:ok, _milestone} =
        Milestones.create_milestone(other, %{"title" => "Somewhere else"}, context.member)

      {:ok, _issue} = Issues.create_issue(other, %{"title" => "Not here"}, context.member)

      # Each page subscribes to its own repository's topic, so another
      # repository's write is not a message this page has to filter -- it never
      # arrives.
      refute render(view) =~ "Somewhere else"
      refute render(view) =~ "Not here"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # Write access withdrawn somewhere else, which is the direction a page cannot
  # notice by watching what the viewer does. The membership is demoted rather
  # than deleted because a project references the membership that owns it.
  defp revoke_write_access!(repository, user) do
    {1, _} =
      Repo.update_all(
        from(membership in Membership,
          where: membership.repository_id == ^repository.id and membership.user_id == ^user.id
        ),
        set: [role: "viewer"]
      )

    :ok
  end

  defp issue_path(repository, issue),
    do: ~p"/#{repository.owner}/#{repository.name}/issues/#{issue.number}"

  defp project_path(repository, project),
    do: ~p"/#{repository.owner}/#{repository.name}/projects/#{project.number}"

  defp pull_request_issue!(repository, author) do
    {:ok, issue} =
      Issues.create_issue(repository, %{"title" => "A proposed change"}, author)

    source = repository_fixture()

    %PullRequest{}
    |> PullRequest.changeset(%{
      repository_id: repository.id,
      issue_id: issue.id,
      head_repository_id: source.id,
      head_ref: "feature",
      head_sha: String.duplicate("a", 40),
      base_ref: "main",
      base_sha: String.duplicate("b", 40)
    })
    |> Repo.insert!()

    issue
  end

  # Telemetry fires in the process that ran the query, so filtering on the
  # LiveView's pid isolates the refresh from the write that provoked it.
  defp capture_queries(pid, fun) do
    handler = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach(
      handler,
      Repo.config()[:telemetry_prefix] ++ [:query],
      fn _event, _measurements, metadata, _config ->
        if self() == pid, do: send(test, {handler, metadata.query})
      end,
      nil
    )

    try do
      fun.()
      drain(handler, [])
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(handler, acc) do
    receive do
      {^handler, query} -> drain(handler, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
