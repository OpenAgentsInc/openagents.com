defmodule OpenAgentsWeb.HomeControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.{Repo, Repositories}

  test "the public homepage is the OpenAgents hero", %{conn: conn} do
    response = get(conn, ~p"/")
    html = html_response(response, 200)

    # OpenAgents deliberately ships its own landing page ("The Agent Forge"),
    # not Sarah's. These assertions match the current product identity.
    assert html =~ "The Agent Forge"
    assert html =~ ~s(action="/auth/github?github_tools=enabled")
    assert html =~ "Log in with GitHub"

    # The scope disclosure was removed from the hero at the owner's direction.
    # GitHub's own consent screen still states the scope before the grant is
    # made, so this asserts the paragraph is gone rather than that it is there.
    refute html =~ ~s(id="github-tools-disclosure")
    refute html =~ "retain an encrypted GitHub grant"

    refute html =~ "One continuing conversation"
    refute html =~ ~s(href="/chat")
    refute html =~ "Account menu"
  end

  test "an authenticated account sees the dashboard, not the pitch", %{conn: conn} do
    conn = log_in_github_user(conn, "authenticated-home-user")
    html = html_response(get(conn, ~p"/"), 200)

    # Someone who has signed in has already been sold. The same route shows the
    # state of the work instead: open issues, projects, and what shipped.
    refute html =~ "The Agent Forge"
    assert html =~ "Open issues"
    assert html =~ "Latest from the changelog"
    assert html =~ ~s(class="dashboard")
  end

  test "an authenticated account sees the dashboard before the first import", %{conn: conn} do
    conn = log_in_github_user(conn, "authenticated-empty-home-user")
    Repositories.initial_repository!() |> Repo.delete!()

    html = html_response(get(conn, ~p"/"), 200)

    assert html =~ ~s(class="dashboard")
    assert html =~ "No repositories yet."
  end

  test "the browser policy permits only the narrow GitHub avatar origin", %{conn: conn} do
    response = get(conn, ~p"/")

    [policy] = get_resp_header(response, "content-security-policy")
    assert policy =~ "img-src 'self' data: https://avatars.githubusercontent.com"
    refute policy =~ ~r/img-src[^;]*\shttps:(?:\s|;)/
  end

  test "the browser policy admits only the response-scoped theme bootstrap", %{conn: conn} do
    first = get(conn, ~p"/")
    second = conn |> recycle() |> get(~p"/")

    [first_policy] = get_resp_header(first, "content-security-policy")
    [second_policy] = get_resp_header(second, "content-security-policy")

    [first_nonce] =
      Regex.run(~r/script-src 'self' 'nonce-([A-Za-z0-9_-]{24})'/, first_policy,
        capture: :all_but_first
      )

    [second_nonce] =
      Regex.run(~r/script-src 'self' 'nonce-([A-Za-z0-9_-]{24})'/, second_policy,
        capture: :all_but_first
      )

    refute first_nonce == second_nonce
    refute first_policy =~ ~r/script-src[^;]*'unsafe-inline'/

    document = first |> html_response(200) |> LazyHTML.from_document()

    assert document
           |> LazyHTML.query(~s{script[nonce="#{first_nonce}"]})
           |> LazyHTML.to_tree()
           |> length() == 1
  end

  test "the landing styles do not use Sarah's cycling verb" do
    css = File.read!("assets/css/app.css")

    # OpenAgents does not ship Sarah's animated landing verb. This assertion
    # only guards against that leftover coming back.
    refute css =~ "landing-verb"
  end
end
