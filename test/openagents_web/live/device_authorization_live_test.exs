defmodule OpenAgentsWeb.DeviceAuthorizationLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "an authenticated user reviews and approves a matching terminal code", %{conn: conn} do
    user = github_user("device-live-approval", "device-live-owner")

    {:ok, _authorization, _device_code, user_code} =
      OpenAgents.DeviceAuthorizations.create(
        OpenAgents.ApiTokens.default_scopes(),
        "Christopher's MacBook"
      )

    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})

    {:ok, view, _html} = live(conn, ~p"/device?user_code=#{user_code}")

    assert has_element?(view, "#device-authorization-review")

    assert has_element?(
             view,
             "#device-requesting-computer[data-device-name=\"Christopher's MacBook\"]"
           )

    assert has_element?(view, "#approve-device")
    refute has_element?(view, "#device-code-invalid")

    view |> element("#approve-device") |> render_click()

    assert has_element?(view, "#device-approved")
    refute has_element?(view, "#device-authorization-review")
  end

  # Still a refusal: no session, no approval, and the code alone grants nothing.
  # What changed with issue #129 is where the refusal sends them. It used to be
  # the bare public root, which forgot why they were there; it is now the
  # sign-in that returns them here with the code still in hand.
  # `OpenAgentsWeb.DeviceSignInReturnTest` proves the whole round trip.
  test "a signed-out browser cannot approve a device code", %{conn: conn} do
    {:ok, _authorization, _device_code, user_code} = OpenAgents.DeviceAuthorizations.create()

    assert {:error, {:redirect, %{to: "/?user_code=" <> ^user_code}}} =
             live(conn, ~p"/device?user_code=#{user_code}")
  end
end
