defmodule OpenAgentsWeb.HomeControllerTest do
  use OpenAgentsWeb.SarahConnCase, async: true
  @moduletag :skip
  test "the public homepage is a focused GitHub login landing page", %{conn: conn} do
    response = get(conn, ~p"/")
    html = html_response(response, 200)

    assert html =~ ~s(id="sarah-landing")
    assert html =~ "Meet OpenAgents."
    assert html =~ ~s(id="github-login-form")
    assert html =~ ~s(action="/auth/github")
    assert html =~ ~s(id="github-login")
    assert html =~ "Log in with GitHub"
    # The page's single primary action carries the notched treatment and the
    # mark of the service it reaches.
    assert html =~ ~s(data-variant="notched")
    assert html =~ ~s(src="/video/landing-hero.mp4")

    # The mark precedes the words, and is decorative because the words name the
    # action already.
    [button] = Regex.run(~r|<button[^>]*id="github-login".*?</button>|s, html)
    assert button =~ ~r|<svg.*?Log in with GitHub|s
    assert button =~ ~s(aria-hidden="true")

    refute html =~ "One continuing conversation"
    refute html =~ ~s(href="/chat")
    refute html =~ "Account menu"
  end

  test "the landing grid is decorative and themed", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    # Structural texture, admitted in one narrow form by DESIGN.md: static,
    # decorative, and reading its colour from the palette rather than a
    # hardcoded stroke. A data URI could not do the last part.
    assert html =~ ~s(class="landing-grid")
    assert html =~ ~s(aria-hidden="true")
    assert html =~ ~s|stroke="var(--line)"|
    refute html =~ "<canvas"
  end

  test "the grid never appears behind reading content", %{conn: conn} do
    conn = log_in_github_user(conn, "grid-scope-user")
    html = conn |> get(~p"/chat") |> response(200)

    refute html =~ "landing-grid"
  end

  test "an authenticated account is sent directly to Sarah", %{conn: conn} do
    conn = log_in_github_user(conn, "authenticated-home-user")
    response = get(conn, ~p"/")

    assert redirected_to(response) == ~p"/chat"
  end

  test "authentication failures are bounded and never echo provider details", %{conn: conn} do
    response = get(conn, ~p"/?auth_error=provider-secret-detail")
    html = html_response(response, 200)

    assert html =~ ~s(id="authentication-error")
    assert html =~ "GitHub login could not be completed. Please try again."
    refute html =~ "provider-secret-detail"
  end

  test "the browser policy permits only the narrow GitHub avatar origin", %{conn: conn} do
    response = get(conn, ~p"/")

    [policy] = get_resp_header(response, "content-security-policy")
    assert policy =~ "img-src 'self' data: https://avatars.githubusercontent.com"
    refute policy =~ ~r/img-src[^;]*\shttps:(?:\s|;)/
  end

  test "the landing statement is static and the shell still adapts" do
    css = File.read!("assets/css/app.css")
    html = File.read!("lib/sarah_web/controllers/home_html/show.html.heex")

    # The cycling verb is retired, so the product has no brand animation left
    # and nothing on this page needs a reduced-motion alternative.
    refute css =~ "landing-verb"
    refute css =~ "landing-heading__"
    refute html =~ "landing-verb"

    assert css =~ "@media (prefers-reduced-motion: reduce)"
    assert css =~ "@media (max-width: 620px)"
  end
end
