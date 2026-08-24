defmodule OpenAgentsWeb.AuthenticatedRouteGateTest do
  @moduledoc """
  The executable enumeration behind IDENTITY-002 and UI-001.

  IDENTITY-002 says every typed, memory, data, voice, and telemetry route fails
  before mutation without an active user, and UI-001 says the public default
  route is an authentication boundary. Both quantify over routes; both were
  proven by `test/openagents_web/auth_gate_test.exs`, which asks eleven
  hand-written paths whether they redirect. A route added without the
  `:authenticated` pipeline is not one of those eleven, so it serves an
  anonymous visitor and every test stays green — the shape ADMIN-001 carried
  before `443c74b`.

  This file derives the population instead. `OpenAgentsWeb.RouteAuthority`
  classifies every entry in the router, and `route_authority_test.exs` already
  fails a route it cannot classify. Each route it classifies
  `:authenticated_browser` is dispatched here without a session, and must
  refuse: a redirect to the public root, or `401` for the session-authenticated
  API routes that answer a client rather than a browser.

  The two GitHub OAuth entries are in this class and refuse the same way. They
  are where a person authenticates, so an anonymous request reaches them, but
  it leaves with an `auth_error` and no session rather than with a page.

  The websocket at `/live` is classified in the same class and is not
  dispatchable here; `OpenAgentsWeb.UserAuth.on_mount/4` gates it and
  `chat_live_test.exs` proves that path.
  """

  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.ConnTest

  alias OpenAgentsWeb.RouteAuthority

  @endpoint OpenAgentsWeb.Endpoint

  test "every authenticated browser route refuses an anonymous request" do
    routes =
      RouteAuthority.inventory()
      |> Enum.filter(&(&1.class == :authenticated_browser and &1.transport == :http))

    assert routes != [], "the route authority classified no authenticated browser route"

    for route <- routes do
      conn = dispatch_anonymously(route)
      location = conn |> Plug.Conn.get_resp_header("location") |> List.first()

      refused? =
        (conn.status == 302 and is_binary(location) and String.starts_with?(location, "/")) or
          conn.status == 401

      assert refused?, """
      `#{route.verb} #{route.path}` is classified `:authenticated_browser` but an
      anonymous request got #{conn.status}#{if location, do: " -> " <> location, else: ""}.

      IDENTITY-002 confines every ordinary server path to the active user's own
      data, and a route that answers without a session has no active user to
      confine it to. Move the route behind the `:authenticated` pipeline, or —
      if it is genuinely public — reclassify it in
      `OpenAgentsWeb.RouteAuthority` and say so in the invariant that covers it.
      """

      refute conn.status == 200,
             "`#{route.verb} #{route.path}` served an anonymous request."
    end
  end

  defp dispatch_anonymously(route) do
    path =
      route.path
      |> String.replace(":owner", "nobody")
      |> String.replace(":repo", "nonexistent")
      |> String.replace(":computer_id", "00000000-0000-4000-8000-000000000001")
      |> String.replace(":id", "00000000-0000-4000-8000-000000000001")

    dispatch(build_conn(), @endpoint, String.to_atom(route.verb), path)
  end
end
