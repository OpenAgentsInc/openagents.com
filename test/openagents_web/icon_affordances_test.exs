defmodule OpenAgentsWeb.IconAffordancesTest do
  @moduledoc """
  Guards the one thing that can go wrong when a visible word is replaced by a
  glyph: the control keeps its name for anyone not looking at it.

  Removing the visible label is a visual decision. Removing the accessible name
  is a defect, and it is invisible in a screenshot, so it is asserted here
  rather than reviewed by eye.
  """

  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "icon-only controls" do
    test "the composer send control is named even though it shows only a glyph", %{conn: conn} do
      conn = log_in_github_user(conn, "icon-send-user")
      {:ok, view, html} = live(conn, ~p"/chat")

      assert has_element?(view, ~s(#send-message[aria-label="Send"]))

      # The glyph itself must not also announce, or the control says it twice.
      refute has_element?(view, ~s(#send-message svg[aria-label]))
      assert has_element?(view, ~s(#send-message svg[aria-hidden="true"]))

      # The visible word is gone; the name is not.
      button = view |> element("#send-message") |> render()
      assert button =~ "<svg"
      refute button =~ "SEND"
      assert html =~ ~s(aria-label="Send")
    end

    test "notice dismissal keeps its name after losing the word CLOSE", %{conn: conn} do
      conn = log_in_github_user(conn, "icon-close-user")
      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(view, ~s(#client-error [aria-label="Dismiss notice"]))
    end
  end

  describe "glyphs beside words" do
    test "are decorative, so the control is announced once", %{conn: conn} do
      conn = log_in_github_user(conn, "icon-decorative-user")
      {:ok, view, _html} = live(conn, ~p"/chat")

      for id <- ~w(load-older) do
        refute has_element?(view, "##{id} svg[aria-label]"),
               "the glyph in ##{id} announces itself alongside its text label"
      end
    end

    test "the memory surface pairs destructive actions with a glyph and keeps the words",
         %{conn: conn} do
      conn = log_in_github_user(conn, "icon-memory-user")
      {:ok, view, _html} = live(conn, ~p"/memory")

      html = render(view)

      assert html =~ "Export ALL DATA"
      assert html =~ "DELETE ALL DATA"
      assert has_element?(view, "#export-all-data svg")
      assert has_element?(view, "#delete-all-data svg")
    end
  end

  describe "icon sourcing" do
    test "no surface hand-writes an svg outside the vendored set" do
      # Every glyph must come from `priv/icons` through `icon/1`. A pasted
      # `<svg>` in a template is how a second, unmanaged icon set starts.
      #
      # `icons.ex` holds the embedded markup and `ui.ex` renders the one
      # governed root element, so both implement the vendored set rather than
      # bypassing it.
      #
      # `graph.ex` is exempt for a different reason: it draws data, not
      # affordances. Its circles, rects and paths are positioned from live SCV
      # geometry and cannot come from a fixed glyph set — there is no icon for
      # "a link terminating on this node's surface at this angle". The rule this
      # test defends is "one icon set", not "no vector output", and a graph node
      # is not an icon. Any glyph *inside* a graph surface still goes through
      # `icon/1`.
      #
      # `og/templates.ex` is exempt for the same class of reason: it emits
      # whole Open Graph card *images* (1200x630 SVG documents rasterized to
      # PNG for crawlers), never in-page affordances. Nothing it draws appears
      # in the product UI.
      exempt = ["ui.ex", "icons.ex", "graph.ex", "templates.ex"]

      offenders =
        "lib/openagents_web/**/*.{ex,heex}"
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, exempt))
        |> Enum.filter(fn path -> path |> File.read!() |> String.contains?("<svg") end)

      assert offenders == [],
             "inline SVG found in #{Enum.join(offenders, ", ")}; use <.icon name=\"...\" />"
    end
  end
end
