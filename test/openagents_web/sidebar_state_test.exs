defmodule OpenAgentsWeb.SidebarStateTest do
  @moduledoc """
  Two sidebar facts that are invisible when they break.

  The first is the Admin row. `sidebar_footer/1` used to default its user to
  `nil`, which made a forgotten attribute indistinguishable from a signed-out
  visitor -- and the docs and component-library layouts both forgot it, so an
  operator browsing either surface silently had no Admin row. It is a required
  attribute now, and the test below is the behavioural half of that.

  The second is which sections the reader has collapsed. That has to reach the
  server, because several sidebar destinations live in different live sessions
  and moving between them is a full page load: state the browser holds alone
  arrives a frame late, and the reader sees a collapsed section paint open and
  then shut. A page that renders the shell without passing the state gets that
  flicker back, and nothing else would say so.
  """

  use OpenAgentsWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias OpenAgents.Repositories.Membership
  alias OpenAgentsWeb.Plugs.SidebarSections

  describe "the admin row" do
    test "an operator sees it on the application shell", %{conn: conn} do
      conn = log_in_admin_user(conn, "operator-shell")
      {:ok, view, _html} = live(conn, ~p"/leaderboard")

      assert has_element?(view, ~s(#sidebar .sidebar-footer a[href="/admin"]))
    end

    test "an operator sees it on the docs surface", %{conn: conn} do
      conn = log_in_admin_user(conn, "operator-docs")
      {:ok, view, _html} = live(conn, ~p"/docs")

      assert has_element?(view, ~s(.sidebar-footer a[href="/admin"]))
    end

    test "an operator sees it on the component library", %{conn: conn} do
      conn = log_in_admin_user(conn, "operator-components")
      {:ok, view, _html} = live(conn, ~p"/components")

      assert has_element?(view, ~s(.sidebar-footer a[href="/admin"]))
    end

    test "an ordinary account sees it on none of them", %{conn: conn} do
      conn = log_in_github_user(conn, "ordinary-account")

      for path <- [~p"/leaderboard", ~p"/docs", ~p"/components"] do
        {:ok, view, _html} = live(conn, path)

        refute has_element?(view, ~s(.sidebar-footer a[href="/admin"])),
               "admin row leaked on #{path}"
      end
    end
  end

  describe "the forum row" do
    test "an ordinary account sees it under Leaderboard on the application shell", %{conn: conn} do
      conn = log_in_github_user(conn, "forum-row-shell")
      {:ok, view, html} = live(conn, ~p"/leaderboard")

      assert has_element?(view, ~s(#sidebar .sidebar-footer a[href="/forum"]))

      footer = html |> String.split(~s(class="sidebar-footer")) |> Enum.at(1)
      leaderboard = :binary.match(footer, ~s(href="/leaderboard"))
      forum = :binary.match(footer, ~s(href="/forum"))

      assert leaderboard != :nomatch and forum != :nomatch
      assert elem(leaderboard, 0) < elem(forum, 0), "Forum must follow Leaderboard"
    end

    test "an operator sees it too, ahead of the admin row", %{conn: conn} do
      conn = log_in_admin_user(conn, "forum-row-operator")
      {:ok, view, _html} = live(conn, ~p"/leaderboard")

      assert has_element?(view, ~s(#sidebar .sidebar-footer a[href="/forum"]))
    end

    # #23: the cutover made the forum reads public, so the row is no longer a
    # link to a login wall. The docs shell is where a visitor meets the footer
    # at all -- the application shell renders no sidebar for one -- so that is
    # where the row has to appear.
    test "a visitor sees it on the docs shell, because the forum reads are public",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/docs")

      assert has_element?(view, ~s(.sidebar-footer a[href="/forum"]))
      assert has_element?(view, ~s(.sidebar-footer a[href="/leaderboard"]))
    end
  end

  describe "collapsed sections survive the first paint" do
    test "a collapsed section renders collapsed, not open-then-corrected", %{conn: conn} do
      conn =
        conn
        |> log_in_chatting_user("collapse-first-paint")
        |> put_req_cookie("sidebar_sections", ~s({"sidebar-section-sarah":false}))

      {:ok, _view, html} = live(conn, ~p"/leaderboard")

      # `open` absent is the whole point: present would mean the browser paints
      # it expanded and a hook shuts it a frame later, which is the flicker.
      assert html =~ ~s(id="sidebar-section-sarah")
      refute html =~ ~r/id="sidebar-section-sarah"[^>]*\sopen/
    end

    test "with no cookie the seed governs, so the section is open", %{conn: conn} do
      conn = log_in_chatting_user(conn, "no-cookie-seed")
      {:ok, _view, html} = live(conn, ~p"/leaderboard")

      assert html =~ ~r/id="sidebar-section-sarah"[^>]*\sopen/
    end

    test "an expanded section stays expanded", %{conn: conn} do
      conn =
        conn
        |> log_in_chatting_user("expanded-stays")
        |> put_req_cookie("sidebar_sections", ~s({"sidebar-section-sarah":true}))

      {:ok, _view, html} = live(conn, ~p"/leaderboard")

      assert html =~ ~r/id="sidebar-section-sarah"[^>]*\sopen/
    end
  end

  # The docs and component-library surfaces are where this used to fail. Their
  # rows mark themselves `aria-current`, and the hook forced any section
  # holding such a row open and wrote that back to the cookie, so the reader's
  # collapse survived on the application shell -- whose sections hold no
  # current row -- and was erased on `/docs` and `/components` on every reload.
  describe "collapsed sections survive on the docs and component surfaces" do
    test "a cold GET of a docs page paints the reader's collapsed sections collapsed", %{
      conn: conn
    } do
      html =
        conn
        |> put_req_cookie("sidebar_sections", ~s({"sidebar-section-transparency":false}))
        |> get(~p"/docs/welcome")
        |> html_response(200)

      refute html =~ ~r/id="sidebar-section-transparency"[^>]*\sopen/
    end

    test "the section holding the page being read stays collapsed if the reader closed it", %{
      conn: conn
    } do
      html =
        conn
        |> put_req_cookie("sidebar_sections", ~s({"sidebar-section-getting-started":false}))
        |> get(~p"/docs/welcome")
        |> html_response(200)

      refute html =~ ~r/id="sidebar-section-getting-started"[^>]*\sopen/
    end

    test "with no cookie the section holding the page being read is open", %{conn: conn} do
      html = conn |> get(~p"/docs/welcome") |> html_response(200)

      assert html =~ ~r/id="sidebar-section-getting-started"[^>]*\sopen/
    end

    test "a navigation within docs keeps the collapse", %{conn: conn} do
      conn = put_req_cookie(conn, "sidebar_sections", ~s({"sidebar-section-issues":false}))

      {:ok, view, _html} = live(conn, ~p"/docs/welcome")
      html = render_patch(view, ~p"/docs/issues")

      refute html =~ ~r/id="sidebar-section-issues"[^>]*\sopen/
    end

    test "the component library honours a collapse the same way", %{conn: conn} do
      html =
        conn
        |> put_req_cookie("sidebar_sections", ~s({"sidebar-section-reference":false}))
        |> get(~p"/components/icons")
        |> html_response(200)

      refute html =~ ~r/id="sidebar-section-reference"[^>]*\sopen/
    end

    # The behavioural half of the above is not renderable from here: the force
    # was in the colocated hook, which only runs in a browser. Pinned at the
    # source, the same way the viewport defaults are.
    test "the hook applies the reader's choice and never writes one for them" do
      source = File.read!("lib/openagents_web/components/layouts.ex")

      refute source =~ ~s([aria-current]),
             "the hook forces the section holding the active row open again"
    end
  end

  # Scoping is a decision, not an accident of naming: one namespace for every
  # surface, keyed by the section title. A section called the same thing in two
  # sidebars is one preference.
  describe "section ids are one namespace across surfaces" do
    test "the id comes from the title alone, not from the surface", %{conn: conn} do
      html = conn |> get(~p"/docs") |> html_response(200)

      assert html =~ ~s(id="sidebar-section-getting-started")
      assert standalone_section_id("Getting started") == "sidebar-section-getting-started"
    end

    test "an explicit id is how a section stands alone" do
      assert standalone_section_id("Getting started", id: "sidebar-section-gallery-demo") ==
               "sidebar-section-gallery-demo"
    end
  end

  # The Issues and Projects rows used to be repository-scoped: they took the
  # `:owner`/`:repo` of whatever page you were on, and fell back to the first
  # repository in your workspace alphabetically. The same row therefore led
  # somewhere different depending on where you clicked it from, and vanished
  # for an account with no membership. They are global now, and these tests
  # say so from both directions.
  describe "global navigation" do
    test "a repository page does not retarget Issues and Projects at that repository", %{
      conn: conn
    } do
      user = github_user("sidebar-current-repository")
      conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})

      {:ok, repository} =
        OpenAgents.Repositories.create_repository(%{
          owner: "navigation-owner",
          name: "navigation-repository",
          visibility: "private"
        })

      {:ok, _membership} = OpenAgents.Repositories.add_member(repository, user, "owner")
      {:ok, view, _html} = live(conn, ~p"/navigation-owner/navigation-repository/issues")

      assert has_element?(view, ~s(#sidebar a[href="/issues"]))
      assert has_element?(view, ~s(#sidebar a[href="/projects"]))

      refute has_element?(
               view,
               ~s(#sidebar a[href="/navigation-owner/navigation-repository/issues"])
             )

      refute has_element?(
               view,
               ~s(#sidebar a[href="/navigation-owner/navigation-repository/projects"])
             )
    end

    test "an account with no repository still gets Issues and Projects", %{conn: conn} do
      user = github_user("sidebar-no-repository")

      OpenAgents.Repo.delete_all(
        from membership in Membership, where: membership.user_id == ^user.id
      )

      conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})

      {:ok, view, _html} = live(conn, ~p"/leaderboard")

      assert has_element?(view, ~s(#sidebar a[href="/repositories"]))
      assert has_element?(view, ~s(#sidebar a[href="/issues"][aria-label="Issues"]))
      assert has_element?(view, ~s(#sidebar a[href="/projects"][aria-label="Projects"]))
    end

    test "the rows read the same from a page in a repository and a page outside one", %{
      conn: conn
    } do
      user = github_user("sidebar-stable-rows")
      conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})

      for {owner, name} <- [
            {"alpha-owner", "alpha-repository"},
            {"zulu-owner", "zulu-repository"}
          ] do
        {:ok, repository} =
          OpenAgents.Repositories.create_repository(%{
            owner: owner,
            name: name,
            visibility: "private"
          })

        {:ok, _membership} = OpenAgents.Repositories.add_member(repository, user, "owner")
      end

      {:ok, from_repository, _html} = live(conn, ~p"/zulu-owner/zulu-repository/issues")
      {:ok, from_elsewhere, _html} = live(conn, ~p"/leaderboard")

      for view <- [from_repository, from_elsewhere] do
        assert has_element?(view, ~s(#sidebar a[href="/issues"]))
        assert has_element?(view, ~s(#sidebar a[href="/projects"]))
      end
    end
  end

  describe "the cookie is reader-supplied, so it is bounded" do
    test "junk, wrong shapes, and unknown keys are dropped" do
      for value <- [
            "not json",
            "[1,2,3]",
            ~s({"sidebar-section-sarah":"yes"}),
            ~s({"../../etc/passwd":true}),
            ~s({"<script>":true}),
            ~s({"SIDEBAR-SECTION-SARAH":true}),
            "%E0%A4%A",
            String.duplicate("x", 4_000)
          ] do
        assert parse(value) == %{}, "admitted #{inspect(value)}"
      end
    end

    test "a well-formed entry survives" do
      assert parse(~s({"sidebar-section-sarah":false})) == %{"sidebar-section-sarah" => false}
    end

    test "a mixed payload keeps only the admissible entries" do
      assert parse(~s({"sidebar-section-sarah":false,"nope":true})) ==
               %{"sidebar-section-sarah" => false}
    end

    test "the number of sections is capped" do
      payload =
        1..200
        |> Map.new(fn n -> {"sidebar-section-s#{n}", false} end)
        |> Jason.encode!()

      parsed = parse(payload)
      assert map_size(parsed) <= 64
    end
  end

  describe "every shell call site passes the state" do
    # A page that renders the shell without it gets the flicker back, silently.
    # Checked at the source rather than by rendering, because the failure is a
    # missing attribute rather than a wrong output.
    test "no `<Layouts.app` omits sidebar_sections" do
      offenders =
        for path <- Path.wildcard("lib/openagents_web/**/*.{ex,heex}"),
            source = File.read!(path),
            [call] <- Regex.scan(~r/<Layouts\.app\b[^>]*>/s, source),
            not String.contains?(call, "sidebar_sections="),
            do: {path, String.slice(call, 0, 90)}

      assert offenders == [], """
      These render the application shell without passing the reader's collapsed
      sections, so a full page load paints their sections open and a hook shuts
      them a frame later:

      #{Enum.map_join(offenders, "\n", fn {file, call} -> "  #{file}\n    #{call}" end)}

      Add `sidebar_sections={assigns[:sidebar_sections]}`.
      """
    end
  end

  describe "viewport defaults" do
    test "desktop starts open and mobile starts closed without a saved browser preference" do
      source = File.read!("lib/openagents_web/components/layouts.ex")

      assert source =~ "const open = this.desktop.matches"
      refute source =~ "openagents:sidebar-desktop"
      refute source =~ "desktopPreference()"
    end
  end

  # The section rendered on its own, so the id it derives can be read without a
  # surface around it.
  defp standalone_section_id(title, options \\ []) do
    html =
      render_component(&OpenAgentsWeb.Layouts.sidebar_section/1,
        title: title,
        id: options[:id],
        inner_block: [
          %{
            __slot__: :inner_block,
            inner_block: fn _changed, _arguments -> "row" end
          }
        ]
      )

    [_match, id] = Regex.run(~r/<details[^>]*\sid="([^"]+)"/, html)
    id
  end

  defp parse(value) do
    :get
    |> Plug.Test.conn("/")
    |> Plug.Test.put_req_cookie("sidebar_sections", value)
    |> Plug.Session.call(
      Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "e")
    )
    |> Plug.Conn.fetch_session()
    |> SidebarSections.call([])
    |> Plug.Conn.get_session("sidebar_sections")
  end
end
