defmodule OpenAgentsWeb.DeviceAuthorizationLiveTest do
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "an authenticated user reviews and approves a matching terminal code", %{conn: conn} do
    user = github_user("device-live-approval", "device-live-owner")
    {:ok, _authorization, _device_code, user_code} = OpenAgents.DeviceAuthorizations.create()
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})

    {:ok, view, _html} = live(conn, ~p"/device?user_code=#{user_code}")

    assert has_element?(view, "#device-authorization-review")
    assert has_element?(view, "#approve-device")
    refute has_element?(view, "#device-code-invalid")

    view |> element("#approve-device") |> render_click()

    assert has_element?(view, "#device-approved")
    refute has_element?(view, "#device-authorization-review")
  end

  test "a signed-out browser cannot approve a device code", %{conn: conn} do
    {:ok, _authorization, _device_code, user_code} = OpenAgents.DeviceAuthorizations.create()

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/device?user_code=#{user_code}")
  end
end
