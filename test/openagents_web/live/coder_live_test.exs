defmodule OpenAgentsWeb.CoderLiveTest do
  @moduledoc """
  The page exists to hand a reader one command, so the command is the test.
  """

  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the page offers the published install command", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/coder")

    assert html =~ "curl -fsSL https://openagents.com/install.sh | sh"

    # This assertion used to run the other way. The binary release had been
    # withdrawn — artifacts and every channel pointer deleted — so the curl
    # command could only fail, and `npm i -g @openagentsinc/cli` was what the
    # page handed out instead. The release is back, `install.sh` is what the
    # documentation and the homepage publish, and the npm package is a
    # different program answering to the same name: two of them on one `PATH`
    # broke `git push` machine-wide (issue #260).
    refute html =~ "@openagentsinc/cli"
  end

  test "every row of the frame is the same width", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/coder")

    # The box is drawn in text, so a row that does not match the others shows
    # as a broken side. It was typed for a 49-column interior while the command
    # row came to 35, and nothing noticed until the command changed length.
    # It is composed from the command now, and this is what holds that.
    [frame] = Regex.run(~r{<pre[^>]*>(.*?)</pre>}s, html, capture: :all_but_first)

    widths =
      frame
      |> String.replace(~r{<[^>]+>}, "")
      |> String.split("\n")
      |> Enum.map(&String.length/1)
      |> Enum.uniq()

    assert length(widths) == 1, "frame rows differ in width: #{inspect(widths)}"
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
