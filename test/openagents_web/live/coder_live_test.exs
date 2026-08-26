defmodule OpenAgentsWeb.CoderLiveTest do
  @moduledoc """
  The page exists to hand a reader one command, so the command is the test.
  """

  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the page offers the published install command", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/coder")

    assert html =~ "npm i -g @openagentsinc/cli"

    # The binary release was withdrawn — artifacts and every channel pointer
    # deleted — so the curl command can only fail, and the build it installed
    # printed fabricated data. Offering it is worse than offering nothing.
    refute html =~ "install.sh"
  end

  test "the page adds no stylesheet of its own", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/coder")

    # It linked a `webtui.css` that was never added, through an `@extra_css`
    # hatch in the root layout, so the page asked for a 404 and rendered by
    # accident on its literal fallbacks. This repository has one component
    # system; a page that needs a second one needs a decision, not a hatch.
    refute html =~ "webtui"

    local_sheets =
      ~r/<link[^>]+rel="stylesheet"[^>]+href="(\/[^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.replace(&1, ~r/\?.*$/, ""))
      |> Enum.uniq()

    assert local_sheets == ["/assets/css/app.css"],
           "/coder links local stylesheets beyond the application bundle: " <>
             inspect(local_sheets)
  end
end
