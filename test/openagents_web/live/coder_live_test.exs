defmodule OpenAgentsWeb.CoderLiveTest do
  @moduledoc """
  The page exists to hand a reader one command, so the command is the test.
  """

  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the page offers the published install command", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/coder")

    assert html =~ "curl -fsSL https://openagents.com/install.sh | bash"
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
