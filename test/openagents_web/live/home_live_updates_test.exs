defmodule OpenAgentsWeb.HomeLiveUpdatesTest do
  @moduledoc """
  The signed-in homepage as a live surface (#154, following #128).

  `93c3383` scoped the dashboard correctly and said in as many words that it
  was a mount-time snapshot. This is that follow-up: every panel now names a
  publisher and re-reads when it hears, so the page stops disagreeing with the
  database the moment anything moves.

  What matters here is not only that a panel changes. It is that it changes
  through the viewer's own authorized read: the messages carry ids, so a
  refresh cannot hand a viewer a row -- or a row counted into a number -- that
  the database would have refused them. Both directions are proved: a write in
  a repository the viewer cannot read moves nothing, and a viewer who loses
  access loses the rows and the count they already had.

  The counts stay aggregates. A live update that measured a collection by
  loading it would reintroduce, once per event, exactly the read `93c3383`
  removed.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias OpenAgents.Changelog
  alias OpenAgents.Forum
  alias OpenAgents.Issues
  alias OpenAgents.Projects
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Membership

  @legacy_actor %{
    actor_ref: "agent:user_ed8297d8-1279-4b43-a1e7-f7867da19e20",
    actor_display_name: "Orrery",
    actor_slug: "orrery"
  }

  setup %{conn: conn} do
    :persistent_term.erase({OpenAgents.Changelog, :cache})
    on_exit(fn -> :persistent_term.erase({OpenAgents.Changelog, :cache}) end)

    owner = github_user("home-live-owner")
    repository = ready_repository!(owner, "live-repository", "private")

    %{
      conn: Plug.Test.init_test_session(conn, %{"user_id" => owner.id}),
      owner: owner,
      repository: repository
    }
  end

  describe "issues" do
    test "an issue opened elsewhere moves the count and the feed", context do
      {:ok, view, _html} = live(context.conn, ~p"/")

      assert integer_at(view, "#dashboard-open-issue-count") == 0

      assert has_element?(
               view,
               ".panel__empty",
               "No open issues in the repositories you can read."
             )

      {:ok, issue} =
        Issues.create_issue(
          context.repository,
          %{"title" => "Opened in another tab"},
          context.owner
        )

      assert integer_at(view, "#dashboard-open-issue-count") == 1
      assert render(view) =~ "Opened in another tab"

      assert has_element?(
               view,
               ~s{a[href="/#{context.repository.owner}/#{context.repository.name}/issues/#{issue.number}"]}
             )
    end

    test "closing an issue elsewhere moves both counts", context do
      {:ok, issue} =
        Issues.create_issue(context.repository, %{"title" => "Already underway"}, context.owner)

      {:ok, view, _html} = live(context.conn, ~p"/")

      assert integer_at(view, "#dashboard-open-issue-count") == 1
      assert integer_at(view, "#dashboard-closed-issue-count") == 0

      {:ok, _closed} = Issues.update_issue(issue, %{"state" => "closed"}, context.owner)

      assert integer_at(view, "#dashboard-open-issue-count") == 0
      assert integer_at(view, "#dashboard-closed-issue-count") == 1
      refute render(view) =~ "Already underway"
    end
  end

  describe "projects" do
    test "a project opened elsewhere moves the count and the list", context do
      {:ok, view, _html} = live(context.conn, ~p"/")

      assert integer_at(view, "#dashboard-open-project-count") == 0

      {:ok, project} =
        Projects.create_project(
          context.repository,
          %{title: "Second quarter board", owner: context.owner.github_login, state: "open"},
          context.owner
        )

      assert integer_at(view, "#dashboard-open-project-count") == 1
      assert render(view) =~ "Second quarter board"

      assert has_element?(
               view,
               ~s{a[href="/#{context.repository.owner}/#{context.repository.name}/projects/#{project.number}"]}
             )
    end
  end

  describe "repositories" do
    test "a repository created elsewhere joins the rail and one deleted leaves it", context do
      {:ok, view, _html} = live(context.conn, ~p"/")

      refute has_element?(view, "#dashboard-repository-list", "second-repository")

      second = ready_repository!(context.owner, "second-repository", "private")
      assert has_element?(view, "#repositories-#{second.id}")

      {:ok, _deleted} =
        Repositories.delete_owned_repository(second.owner, second.name, context.owner)

      refute has_element?(view, "#repositories-#{second.id}")
    end

    test "the rail re-reads one row rather than the whole collection", context do
      {:ok, view, _html} = live(context.conn, ~p"/")

      other = ready_repository!(context.owner, "other-repository", "private")

      sql =
        capture_queries(view.pid, fn ->
          Repositories.broadcast_repository_change(other.id)
          render(view)
        end)

      # `get_visible_repository/2` names the row it wants. A rail that answered
      # a push by reloading every repository the viewer can read would be the
      # expensive half of the defect this fixes.
      repository_reads = Enum.filter(sql, &String.contains?(&1, ~s(FROM "repositories")))

      assert repository_reads != []
      assert Enum.all?(repository_reads, &bounded_read?/1)
    end
  end

  describe "the forum panel" do
    test "a post written elsewhere joins the panel", context do
      board = board!("product-promises", "Product promises")

      {:ok, view, _html} = live(context.conn, ~p"/")

      assert has_element?(view, ".panel__empty", "No posts yet on the boards you can read.")

      topic = topic!(board, "What a promise costs", "what-a-promise-costs")

      assert has_element?(view, "#dashboard-post-list")
      assert has_element?(view, ~s{a[href="/forum/t/#{topic.id}"]}, "What a promise costs")

      {:ok, reply} =
        Forum.create_post(topic, Map.merge(@legacy_actor, %{body_text: "Rather less than that"}))

      assert has_element?(view, "#dashboard-post-#{reply.id}")

      # The identity the post was written under, not one resolved for it: a
      # migrated post keeps its legacy byline until a claim binds it, and a
      # live refresh must not attribute it differently from a mount.
      assert has_element?(view, "#dashboard-post-#{reply.id} .post-rail__meta", "Orrery")
    end

    test "a post on a board kept off listings never arrives", context do
      void = board!("void", "Void", discoverability: "unlisted")

      {:ok, view, _html} = live(context.conn, ~p"/")

      topic = topic!(void, "Smoke test", "smoke-test")

      # The message reached the page -- the panel re-read -- and the panel's
      # own scope refused the row, which is what makes this an authorization
      # result rather than an undelivered broadcast.
      refute has_element?(view, ~s{a[href="/forum/t/#{topic.id}"]})
      assert has_element?(view, ".panel__empty", "No posts yet on the boards you can read.")
    end
  end

  describe "the changelog rail" do
    test "an appended entry joins the rail", context do
      {:ok, view, _html} = live(context.conn, ~p"/")

      refute render(view) =~ "Moved the counts beside the issues they count"

      {:ok, _entry} = record_entry!("d00dfeed", "Moved the counts beside the issues they count")

      assert has_element?(
               view,
               ".changelog-rail__summary",
               "Moved the counts beside the issues they count"
             )
    end

    test "a client that reconnects reads the current ledger, not the cached one", context do
      # The rail is served from a five-second cache, which is what a remounting
      # client reads. Left in place it would hand a page that dropped and came
      # back the ledger as it was.
      {:ok, _view, _html} = live(context.conn, ~p"/")

      {:ok, _entry} = record_entry!("feedbeef", "Landed while the client was away")

      {:ok, reconnected, html} = live(context.conn, ~p"/")

      assert html =~ "Landed while the client was away"

      assert has_element?(
               reconnected,
               ".changelog-rail__summary",
               "Landed while the client was away"
             )
    end
  end

  describe "authorization" do
    test "a write in a repository the viewer cannot read moves nothing", context do
      stranger = github_user("home-live-stranger")
      conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => stranger.id})

      {:ok, view, _html} = live(conn, ~p"/")

      before_open = integer_at(view, "#dashboard-open-issue-count")

      {:ok, _issue} =
        Issues.create_issue(context.repository, %{"title" => "Not for you"}, context.owner)

      {:ok, _project} =
        Projects.create_project(
          context.repository,
          %{title: "Not your board", owner: context.owner.github_login, state: "open"},
          context.owner
        )

      html = render(view)

      refute html =~ "Not for you"
      refute html =~ "Not your board"
      assert integer_at(view, "#dashboard-open-issue-count") == before_open
      assert integer_at(view, "#dashboard-open-issue-count") == 0
      assert integer_at(view, "#dashboard-open-project-count") == 0

      # The owner of the same repository does see both, which is what makes the
      # refusal above an authorization result rather than an empty database.
      {:ok, owner_view, _html} = live(context.conn, ~p"/")
      assert integer_at(owner_view, "#dashboard-open-issue-count") == 1
      assert integer_at(owner_view, "#dashboard-open-project-count") == 1
    end

    test "a viewer who loses access loses the rows and the count they had", context do
      member = github_user("home-live-member")

      Repo.insert!(%Membership{
        repository_id: context.repository.id,
        user_id: member.id,
        role: "viewer"
      })

      conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => member.id})

      {:ok, _issue} =
        Issues.create_issue(context.repository, %{"title" => "Readable for now"}, context.owner)

      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Readable for now"
      assert integer_at(view, "#dashboard-open-issue-count") == 1
      assert has_element?(view, "#repositories-#{context.repository.id}")

      Repo.delete_all(
        from membership in Membership,
          where:
            membership.repository_id == ^context.repository.id and
              membership.user_id == ^member.id
      )

      # The same announcement the next write would carry. The page re-reads
      # through a predicate that no longer admits the repository.
      Repositories.broadcast_issues(context.repository.id)
      Repositories.broadcast_repository_change(context.repository.id)

      refute render(view) =~ "Readable for now"
      assert integer_at(view, "#dashboard-open-issue-count") == 0
      refute has_element?(view, "#repositories-#{context.repository.id}")
    end
  end

  describe "cost" do
    test "a live update counts with aggregates rather than by loading the collection",
         context do
      for index <- 1..3 do
        {:ok, _issue} =
          Issues.create_issue(context.repository, %{"title" => "Issue #{index}"}, context.owner)
      end

      {:ok, view, _html} = live(context.conn, ~p"/")

      sql =
        capture_queries(view.pid, fn ->
          Repositories.broadcast_issues(context.repository.id)
          Repositories.broadcast_projects(context.repository.id)
          render(view)
        end)

      issue_reads = Enum.filter(sql, &String.contains?(&1, ~s(FROM "issues")))
      project_reads = Enum.filter(sql, &String.contains?(&1, ~s(FROM "projects")))

      assert issue_reads != []
      assert project_reads != []

      # The numbers beside a panel cost an aggregate, and the rows beside them
      # cost one bounded page. Nothing here reads a collection to measure it.
      assert Enum.any?(issue_reads, &aggregate?/1)
      assert Enum.any?(project_reads, &aggregate?/1)
      assert Enum.all?(issue_reads, &bounded_read?/1)
      assert Enum.all?(project_reads, &bounded_read?/1)
    end

    test "a burst of issue writes leaves the other panels alone", context do
      board = board!("product-promises", "Product promises")
      topic!(board, "Untouched by an issue burst", "untouched")

      {:ok, view, _html} = live(context.conn, ~p"/")

      sql =
        capture_queries(view.pid, fn ->
          for _ <- 1..5, do: Repositories.broadcast_issues(context.repository.id)
          render(view)
        end)

      # Which panels are stale is remembered beside the timer that fires them,
      # so an issue burst never re-reads the forum, the ledger, or the projects.
      refute Enum.any?(sql, &String.contains?(&1, ~s(FROM "forum_posts")))
      refute Enum.any?(sql, &String.contains?(&1, ~s(FROM "projects")))
      refute Enum.any?(sql, &String.contains?(&1, ~s(FROM "changelog_entries")))
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # An aggregate, or a page with a ceiling on it. `IN` subqueries carry their
  # own bound: the id list was already read from a bounded page.
  defp bounded_read?(sql),
    do: aggregate?(sql) or String.contains?(sql, "LIMIT") or String.contains?(sql, "= ANY(")

  defp aggregate?(sql), do: String.contains?(sql, "count(")

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

  defp integer_at(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
    |> String.to_integer()
  end

  defp record_entry!(prefix, summary) do
    Changelog.record(%{
      repo: "openagents.com",
      sha: String.pad_trailing(prefix, 40, "0"),
      summary: summary,
      category: "ui",
      source: "operator",
      entry_at: DateTime.utc_now(),
      visibility: "l2"
    })
  end

  defp board!(slug, title, opts \\ []) do
    {:ok, board} =
      %Forum.Forum{}
      |> Forum.Forum.changeset(%{
        slug: slug,
        title: title,
        visibility: Keyword.get(opts, :visibility, "public"),
        discoverability: Keyword.get(opts, :discoverability, "listed")
      })
      |> Repo.insert()

    board
  end

  defp topic!(board, title, slug) do
    {:ok, topic} =
      Forum.create_topic(
        board,
        Map.merge(@legacy_actor, %{
          title: title,
          slug: slug,
          body_text: "Body of #{title}",
          idempotency_key: Ecto.UUID.generate()
        })
      )

    topic
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
