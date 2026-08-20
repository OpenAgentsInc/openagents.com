defmodule OpenAgentsWeb.HomeControllerTest do
  use OpenAgentsWeb.ConnCase, async: true

  test "the public homepage is the OpenAgents hero", %{conn: conn} do
    response = get(conn, ~p"/")
    html = html_response(response, 200)

    # OpenAgents deliberately ships its own landing page ("The Agent Forge"),
    # not Sarah's. These assertions match the current product identity.
    assert html =~ "The Agent Forge"
    assert html =~ ~s(action="/auth/github?github_tools=enabled")
    assert html =~ "Sign in and enable GitHub tools"
    assert html =~ ~s(id="github-tools-disclosure")
    assert html =~ "retain an encrypted GitHub grant"
    assert html =~ "read/write"

    refute html =~ "One continuing conversation"
    refute html =~ ~s(href="/chat")
    refute html =~ "Account menu"
  end

  test "an authenticated account sees the OpenAgents home", %{conn: conn} do
    conn = log_in_github_user(conn, "authenticated-home-user")
    response = get(conn, ~p"/")

    # The owner chose to keep authenticated users on the marketing home page
    # rather than immediately redirecting into chat. This differs from Sarah.
    assert html_response(response, 200) =~ "The Agent Forge"
  end

  test "the browser policy permits only the narrow GitHub avatar origin", %{conn: conn} do
    response = get(conn, ~p"/")

    [policy] = get_resp_header(response, "content-security-policy")
    assert policy =~ "img-src 'self' data: https://avatars.githubusercontent.com"
    refute policy =~ ~r/img-src[^;]*\shttps:(?:\s|;)/
  end

  test "the landing styles do not use Sarah's cycling verb" do
    css = File.read!("assets/css/app.css")

    # OpenAgents does not ship Sarah's animated landing verb. This assertion
    # only guards against that leftover coming back.
    refute css =~ "landing-verb"
  end
end
