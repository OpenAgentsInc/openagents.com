defmodule OpenAgentsWeb.DeviceSignInReturnTest do
  @moduledoc """
  Issue #129: signing in from the terminal was two logins wearing one name.

  A reader who is not signed in and opens the link their terminal printed —
  `/device?user_code=…` — used to be bounced to the public root, where nothing
  said why they were there. Signing in put them on the dashboard, and the
  approval they had actually come for was an errand still to run, with the code
  back in the terminal they had left.

  This proves the return path: the bounce remembers the code, the sign-in
  carries it across the OAuth round trip, and the reader lands back on the
  approval with the code already in hand.

  The adversarial half matters as much as the working one. The value that
  decides where a sign-in lands arrives in a URL that anyone can write, and it
  is printed back onto a page. So the assertions here are not "a code survives"
  but "only a code survives": every crafted `?user_code=` must leave the reader
  exactly where the old behavior left them, on the public root with nothing
  remembered, and must never reach the session, the redirect, or the page.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.DeviceAuthorizations
  alias OpenAgentsWeb.UserAuth

  setup {Req.Test, :verify_on_exit!}

  setup do
    original = Application.fetch_env!(:openagents, :github_oauth)

    Application.put_env(
      :openagents,
      :github_oauth,
      Keyword.put(original, :request_options, plug: {Req.Test, __MODULE__})
    )

    on_exit(fn -> Application.put_env(:openagents, :github_oauth, original) end)
    :ok
  end

  test "the sign-in a device code sends a reader through returns them to the approval", %{
    conn: conn
  } do
    {:ok, _authorization, _device_code, user_code} = DeviceAuthorizations.create()

    # 1. The terminal's link, opened by a browser with no session.
    bounced = get(conn, ~p"/device?user_code=#{user_code}")

    assert redirected_to(bounced) == "/?user_code=#{user_code}"
    assert get_session(bounced, UserAuth.device_session_key()) == user_code

    # 2. The page they land on says what the sign-in is for and shows the code,
    #    rather than presenting itself as a homepage.
    landing = bounced |> recycle() |> get(~p"/?user_code=#{user_code}")
    landing_html = html_response(landing, 200)

    assert landing_html =~ ~s(id="device-sign-in")
    assert landing_html =~ user_code
    assert landing_html =~ "authorize your terminal"

    # 3. One ordinary sign-in. Nothing about it names the device: the code
    #    rides in the session, so any sign-in control on the page returns them.
    started =
      landing
      |> recycle()
      |> put_req_header("x-csrf-token", Plug.CSRFProtection.get_csrf_token())
      |> post(~p"/auth/github?github_tools=enabled")

    state = oauth_state(started)
    expect_github(4_129, "device-return-person")

    authenticated =
      started
      |> recycle()
      |> get(~p"/auth/github/callback?code=valid-code&state=#{state}")

    # 4. The sign-in returns them to the approval, code in hand -- not to the
    #    dashboard with the errand still to run.
    assert redirected_to(authenticated) == "/device?user_code=#{user_code}"
    assert get_session(authenticated, "user_id")

    # The code has done its work and does not linger to redirect a later
    # sign-in somewhere the reader did not ask to go.
    assert get_session(authenticated, UserAuth.device_session_key()) == nil

    # 5. Approving is the next click. The code is already matched, so the
    #    review is on screen without anything being retyped.
    signed_in = recycle(authenticated)

    {:ok, view, _html} = live(signed_in, "/device?user_code=#{user_code}")

    assert has_element?(view, "#device-authorization-review")
    assert has_element?(view, "#approve-device")
    refute has_element?(view, "#device-code-invalid")

    view |> element("#approve-device") |> render_click()

    assert has_element?(view, "#device-approved")
  end

  test "a sign-in that did not start at the device page still lands on the dashboard", %{
    conn: conn
  } do
    started =
      conn
      |> init_test_session(%{})
      |> put_req_header("x-csrf-token", Plug.CSRFProtection.get_csrf_token())
      |> post(~p"/auth/github?github_tools=enabled")

    state = oauth_state(started)
    expect_github(4_130, "ordinary-sign-in-person")

    authenticated =
      started
      |> recycle()
      |> get(~p"/auth/github/callback?code=valid-code&state=#{state}")

    assert redirected_to(authenticated) == ~p"/sarah"
  end

  test "the device page without a code refuses exactly as it always did", %{conn: conn} do
    bounced = get(conn, ~p"/device")

    assert redirected_to(bounced) == "/"
    assert get_session(bounced, UserAuth.device_session_key()) == nil
  end

  # Everything a link can carry that is not a code this application minted. The
  # value is a redirect target and page content, so each one has to be refused
  # before it becomes either.
  #
  # `user_code[]` is here because a query string can produce a list rather than
  # a string, and a cast that only guarded binaries would raise on it.
  @crafted [
    {"an absolute URL", "https://evil.example/steal"},
    {"a scheme-relative URL", "//evil.example/steal"},
    {"a path traversal", "/../../admin"},
    {"another path on this host", "/settings/api-tokens"},
    {"markup", "<script>alert(1)</script>"},
    {"a quote breaking an attribute", ~s(ABCD-EFGH" onload=")},
    {"a header injection", "ABCD-EFGH\r\nSet-Cookie: user_id=1"},
    {"a second line", "ABCD-EFGH\nADCD-EFGH"},
    {"an appended query", "ABCD-EFGH?next=/admin"},
    {"an appended fragment", "ABCD-EFGH#/admin"},
    {"a code too long", "ABCD-EFGHJ"},
    {"a code too short", "ABC-EFGH"},
    {"the wrong separator", "ABCD_EFGH"},
    {"no separator", "ABCDEFGH"},
    {"characters the alphabet excludes", "IOL1-0OI1"},
    {"an empty value", ""},
    {"only whitespace", "   "},
    {"a list rather than a string", ["ABCD-EFGH"]}
  ]

  for {what, crafted} <- @crafted do
    test "a crafted user_code -- #{what} -- carries nothing across the sign-in", %{conn: conn} do
      crafted = unquote(Macro.escape(crafted))

      bounced = get(conn, device_path(crafted))

      assert redirected_to(bounced) == "/",
             "`#{inspect(crafted)}` decided where the reader went."

      assert get_session(bounced, UserAuth.device_session_key()) == nil,
             "`#{inspect(crafted)}` was remembered across the sign-in."

      # And it cannot get in the back way either: even carried all the way to a
      # completed sign-in, it does not become a landing path.
      started =
        bounced
        |> recycle()
        |> put_req_header("x-csrf-token", Plug.CSRFProtection.get_csrf_token())
        |> post(~p"/auth/github?github_tools=enabled")

      state = oauth_state(started)
      expect_github(4_131, "crafted-code-person")

      authenticated =
        started
        |> recycle()
        |> get(~p"/auth/github/callback?code=valid-code&state=#{state}")

      assert redirected_to(authenticated) == ~p"/sarah"
    end
  end

  # The bounce and the landing both go through `cast_user_code/1`, so this pins
  # what it admits directly rather than only through the routes that use it.
  test "only the shape this application mints casts" do
    {:ok, _authorization, _device_code, minted} = DeviceAuthorizations.create()

    assert DeviceAuthorizations.cast_user_code(minted) == {:ok, minted}

    # A code read off one screen and typed into another arrives however the
    # reader typed it.
    assert DeviceAuthorizations.cast_user_code(String.downcase(minted)) == {:ok, minted}
    assert DeviceAuthorizations.cast_user_code("  " <> minted <> "  ") == {:ok, minted}

    for {_what, crafted} <- @crafted do
      assert DeviceAuthorizations.cast_user_code(crafted) == :error,
             "`#{inspect(crafted)}` cast as a user code."
    end

    assert DeviceAuthorizations.cast_user_code(nil) == :error
    assert DeviceAuthorizations.cast_user_code(%{"user_code" => "ABCD-EFGH"}) == :error
  end

  # Built by hand rather than with `~p`, because half the point is that these
  # are query strings a verified route would refuse to construct. Percent
  # encoding is what a browser does, and Plug decodes it back before anything
  # here sees it, so `%0D%0A` reaches the cast as a real CRLF.
  defp device_path(crafted) when is_list(crafted),
    do: "/device?" <> URI.encode_query(Enum.map(crafted, &{"user_code[]", &1}))

  defp device_path(crafted), do: "/device?" <> URI.encode_query(%{"user_code" => crafted})

  defp oauth_state(conn) do
    conn
    |> redirected_to()
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("state")
  end

  defp expect_github(github_id, login) do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "ephemeral-github-token",
        "scope" => "repo,read:org"
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "id" => github_id,
        "login" => login,
        "avatar_url" => "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })
    end)
  end
end
