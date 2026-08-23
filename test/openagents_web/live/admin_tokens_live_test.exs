defmodule OpenAgentsWeb.AdminTokensLiveTest do
  @moduledoc """
  `/admin/tokens` gates like every operator surface and renders aggregate
  token counts and rates only. Nothing on the page names conversation, run,
  or report content.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "access" do
    test "the operator reaches the surface", %{conn: conn} do
      conn = log_in_admin_user(conn, "tokens-operator")

      {:ok, _view, html} = live(conn, ~p"/admin/tokens")

      assert html =~ "Token productivity"
    end

    test "an ordinary authenticated account is redirected and told nothing", %{conn: conn} do
      conn = log_in_github_user(conn, "tokens-ordinary")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/tokens")

      response = get(conn, ~p"/admin/tokens")
      assert redirected_to(response) == ~p"/"
    end

    test "an unauthenticated visitor is redirected", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/tokens")
    end
  end

  describe "report" do
    test "renders the aggregate sections and refreshes", %{conn: conn} do
      conn = log_in_admin_user(conn, "tokens-loaded")

      {:ok, view, _html} = live(conn, ~p"/admin/tokens")
      render(view)

      assert has_element?(view, "#tokens-productive")
      assert has_element?(view, "#tokens-rates")
      assert has_element?(view, "#tokens-sources-table")
      assert has_element?(view, "#tokens-generated-at")

      html = render(view)
      assert html =~ "Merged work"
      assert html =~ "Closed issues"
      assert html =~ "Verified receipts"
      assert html =~ "Cache hit rate"
      assert html =~ "Input share"

      assert view |> element("#tokens-refresh") |> render_click() =~ "Token productivity"
      assert has_element?(view, "#tokens-generated-at")
    end
  end
end
