defmodule OpenAgentsWeb.ForumClaimLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Forum

  setup %{conn: conn} do
    user = github_user("forum-claim")
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})

    %{conn: conn, user: user}
  end

  test "submitting a claim creates a pending link", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/forum/claim")

    view
    |> form("#claim-form", claim: %{actor_ref: "agent:user_ed8297d8-1279-4b43-a1e7-f7867da19e20"})
    |> render_submit()

    assert [%{status: "pending"}] = Forum.list_actor_links(user)
    assert render(view) =~ "Claim submitted for review"
  end

  test "approving a claim through the operator surface links the identity", %{
    conn: conn,
    user: user
  } do
    admin = github_user("forum-admin")

    previous = Application.get_env(:openagents, :admin_github_ids)
    Application.put_env(:openagents, :admin_github_ids, [admin.github_id])
    on_exit(fn -> Application.put_env(:openagents, :admin_github_ids, previous) end)

    {:ok, _view, _html} = live(conn, ~p"/forum/claim")
    {:ok, link} = Forum.start_actor_link(user, "agent:user_ed8297d8")

    # The operator approves from the claims queue.
    {:ok, admin_view, _html} =
      conn
      |> Plug.Test.init_test_session(%{"user_id" => admin.id})
      |> live(~p"/admin/forum/claims")

    admin_view
    |> element(~s{button[phx-value-id="#{link.id}"][data-variant="primary"]})
    |> render_click()

    assert Forum.actor_user("agent:user_ed8297d8").id == user.id
  end
end
