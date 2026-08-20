defmodule OpenAgentsWeb.UIGalleryLiveTest do
  @moduledoc """
  The gallery is routed only under `:dev_routes`, so it is mounted in isolation
  here. Rendering it exercises every `OpenAgentsWeb.SarahUI` component in every variant
  and state at once, which catches a primitive that unit tests render in
  isolation but that breaks inside a real LiveView.
  """

  use OpenAgentsWeb.SarahConnCase, async: true
  import Phoenix.LiveViewTest

  test "renders every component variant without raising", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, OpenAgentsWeb.UIGalleryLive)

    # Buttons: every variant and size reaches the DOM.
    for variant <- ~w(primary secondary outline ghost destructive link) do
      assert html =~ ~s(data-variant="#{variant}")
    end

    for size <- ~w(xs sm lg) do
      assert html =~ ~s(data-size="#{size}")
    end

    # Every status and voice state the product can render.
    for state <- ~w(idle connected running succeeded failed refused listening speaking muted) do
      assert html =~ ~s(data-state="#{state}")
    end

    # Surfaces.
    assert html =~ ~s(class="alert)
    assert html =~ ~s(class="card)
    assert html =~ ~s(class="item)
    assert html =~ ~s(class="empty)
    assert html =~ ~s(class="avatar)
    assert html =~ ~s(class="badge)
    assert html =~ ~s(class="field)
    assert html =~ ~s(class="input)
    assert html =~ ~s(class="textarea)
    assert html =~ "<kbd"
  end

  test "the gallery is not routable outside development", %{conn: conn} do
    # `:dev_routes` is unset in the test environment, so the route is not
    # compiled. A verification surface must never become reachable in
    # production: INVARIANTS.md UI-001 admits no navigation or settings chrome.
    assert conn |> get("/dev/ui") |> Map.fetch!(:status) == 404
  end
end
