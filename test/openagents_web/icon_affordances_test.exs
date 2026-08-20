defmodule OpenAgentsWeb.IconAffordancesTest do
  @moduledoc """
  Guards the one thing that can go wrong when a visible word is replaced by a
  glyph: the control keeps its name for anyone not looking at it.

  Removing the visible label is a visual decision. Removing the accessible name
  is a defect, and it is invisible in a screenshot, so it is asserted here
  rather than reviewed by eye.
  """

  use OpenAgentsWeb.SarahConnCase
  @moduletag :skip
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

      for id <- ~w(load-older toggle-memory) do
        refute has_element?(view, "##{id} svg[aria-label]"),
               "the glyph in ##{id} announces itself alongside its text label"
      end
    end

    test "the memory surface pairs destructive actions with a glyph and keeps the words",
         %{conn: conn} do
      conn = log_in_github_user(conn, "icon-memory-user")
      {:ok, view, _html} = live(conn, ~p"/chat")

      html = view |> element("#toggle-memory") |> render_click()

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
      # The landing grid is a documented exception: it is a background pattern,
      # not an icon, and it has to be a DOM SVG so its stroke can read `--line`
      # rather than being baked into an opaque data URI. See DESIGN.md.
      grid = "lib/sarah_web/controllers/home_html/show.html.heex"

      assert File.read!(grid) =~ "landing-grid",
             "the inline-SVG exemption for #{grid} is stale; it no longer holds the grid"

      offenders =
        "lib/sarah_web/**/*.{ex,heex}"
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, ["ui.ex", "icons.ex"]))
        |> Enum.reject(&(&1 == grid))
        |> Enum.filter(fn path -> path |> File.read!() |> String.contains?("<svg") end)

      assert offenders == [],
             "inline SVG found in #{Enum.join(offenders, ", ")}; use <.icon name=\"...\" />"
    end
  end
end
