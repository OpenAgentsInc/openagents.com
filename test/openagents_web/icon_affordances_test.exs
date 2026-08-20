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
      # The exempt files implement the vendored set. `icons.ex` holds the
      # embedded SVG markup, while `ui.ex` and `core_components.ex` render it.
      # The assertions below fail if an exemption stops being icon plumbing.
      renderers = ["lib/openagents_web/components/core_components.ex"]

      for renderer <- renderers do
        assert File.read!(renderer) =~ "OpenAgentsWeb.Icons.fetch!",
               "the inline-SVG exemption for #{renderer} is stale; it no longer renders the vendored set"
      end

      offenders =
        "lib/openagents_web/**/*.{ex,heex}"
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, ["ui.ex", "icons.ex"]))
        |> Enum.reject(&(&1 in renderers))
        |> Enum.filter(fn path -> path |> File.read!() |> String.contains?("<svg") end)

      assert offenders == [],
             "inline SVG found in #{Enum.join(offenders, ", ")}; use <.icon name=\"...\" />"
    end
  end
end
