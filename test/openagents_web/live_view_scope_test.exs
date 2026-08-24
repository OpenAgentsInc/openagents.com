defmodule OpenAgentsWeb.LiveViewScopeTest do
  @moduledoc """
  The executable enumeration behind IDENTITY-002's LiveView event clause.

  IDENTITY-002 says a route parameter, form value, mutable GitHub login, or
  LiveView event must not select another user, owner, or conversation. The
  route half is enumerated by `OpenAgentsWeb.AuthenticatedRouteGateTest`, which
  dispatches every route `OpenAgentsWeb.RouteAuthority` classifies
  `:authenticated_browser`. A route table cannot see the event half: a
  `handle_event/3` clause resolving a record from its own params is invisible
  to it, exactly as forum moderation inside a `:public_read` route was
  invisible to it for ADMIN-001.

  Two mechanisms carry the event half, and both are enumerated here.

  **Who is acting.** `OpenAgentsWeb.UserAuth.on_mount/4` attaches a
  `:handle_event` hook in the `:ensure_authenticated` and `:ensure_admin`
  stages. The hook re-reads the account from
  `OpenAgents.Accounts.get_active_user/1` before every event, so a session
  whose account was deactivated — or demoted — between mount and click is
  halted rather than served. The population is the LiveView routes in the
  router, joined to the live session each sits in, so a LiveView placed in a
  session without the hook fails here.

  **What is being resolved.** No LiveView reaches `OpenAgents.Repo`. A view
  that builds its own query is a surface where the scope rule is restated from
  memory, which is how a handler comes to resolve a record from its own params;
  keeping every read in a context keeps the rule in one place. The population is
  read from each LiveView's compiled BEAM import table.

  **What is not enumerated.** A context function that itself takes no acting
  principal, called from a handler with a caller-supplied identifier, passes
  both tests. IDENTITY-002 records that residue rather than claiming it.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Accounts
  alias OpenAgentsWeb.RouteAuthority

  # Every live session in the router, with the `on_mount` stages it declares.
  # `:ensure_authenticated` and `:ensure_admin` are the two that attach a
  # `:handle_event` hook; `:mount_current_user` attaches none, which is why a
  # session carrying only it may serve public reads and nothing else.
  @live_sessions %{
    authenticated: [{OpenAgentsWeb.UserAuth, :ensure_authenticated}],
    components: [{OpenAgentsWeb.UserAuth, :mount_current_user}],
    docs: [{OpenAgentsWeb.UserAuth, :mount_current_user}],
    forge_issues: [{OpenAgentsWeb.UserAuth, :mount_current_user}],
    operator: [
      {OpenAgentsWeb.UserAuth, :ensure_authenticated},
      {OpenAgentsWeb.UserAuth, :ensure_admin}
    ],
    operator_chat: [
      {OpenAgentsWeb.UserAuth, :ensure_authenticated},
      {OpenAgentsWeb.UserAuth, :ensure_admin}
    ],
    public: [{OpenAgentsWeb.UserAuth, :mount_current_user}],
    repository_code: [{OpenAgentsWeb.UserAuth, :mount_current_user}]
  }

  # The stages that attach a `:handle_event` hook re-resolving the acting
  # account. Adding a stage without one, or dropping the hook from one of
  # these, is what the behavioural tests below refuse.
  @actor_guarding_stages [
    {OpenAgentsWeb.UserAuth, :ensure_authenticated},
    {OpenAgentsWeb.UserAuth, :ensure_admin}
  ]

  # LiveViews permitted to reach `OpenAgents.Repo` directly. The set is empty,
  # and it is stated rather than assumed so that admitting one is a decision
  # someone writes down.
  @repo_reaching_live_views []

  describe "who is acting" do
    test "the live sessions in the router are exactly the ones named here" do
      assert_exact_set(
        Enum.map(live_routes(), fn {_verb, _path, _view, session} ->
          {session.name, Enum.map(session.extra.on_mount, & &1.id)}
        end),
        Enum.map(@live_sessions, fn {name, stages} -> {name, stages} end),
        "is a live session in the router; say which authority stages it mounts"
      )
    end

    test "every authenticated or operator LiveView sits in an actor-guarded session" do
      classes = route_classes()

      guarded =
        for {verb, path, view, session} <- live_routes(),
            Map.get(classes, {verb, path}) in [:authenticated_browser, :operator] do
          stages = Enum.map(session.extra.on_mount, & &1.id)

          assert Enum.any?(stages, &(&1 in @actor_guarding_stages)),
                 """
                 #{inspect(view)} serves #{String.upcase(verb)} #{path}, which
                 #{inspect(RouteAuthority)} classifies
                 #{inspect(Map.get(classes, {verb, path}))}, from the
                 #{inspect(session.name)} live session. That session mounts
                 #{inspect(stages)} and none of them re-resolves the acting
                 account before an event. IDENTITY-002 says a LiveView event
                 must not select another user.
                 """

          view
        end

      assert length(Enum.uniq(guarded)) >= 20
    end

    test "a demoted operator's next event is halted rather than served" do
      operator = github_user("live-scope-operator")
      previous = Application.get_env(:openagents, :admin_github_ids)
      Application.put_env(:openagents, :admin_github_ids, [operator.github_id])
      on_exit(fn -> Application.put_env(:openagents, :admin_github_ids, previous) end)

      {:ok, view, _html} = login(operator) |> live(~p"/admin/forum/claims")

      # Still signed in, still active, no longer an operator. The claim id is
      # someone else's record, which is the shape IDENTITY-002 names.
      Application.put_env(:openagents, :admin_github_ids, [])

      assert {:error, {:redirect, %{to: "/"}}} =
               render_click(view, "approve", %{"id" => Ecto.UUID.generate()})
    end

    test "a deactivated account's next event is halted rather than served" do
      user = github_user("live-scope-deactivated")
      {:ok, view, _html} = login(user) |> live(~p"/settings/api-tokens")

      {:ok, _banned} = Accounts.ban_user(user, "identity_002_live_scope_probe")

      assert {:error, {:redirect, %{to: "/"}}} =
               render_click(view, "revoke", %{"id" => Ecto.UUID.generate()})
    end
  end

  describe "what is being resolved" do
    test "no LiveView reaches OpenAgents.Repo" do
      assert_exact_set(
        Enum.filter(live_views(), &reaches_repo?/1),
        @repo_reaching_live_views,
        "is a LiveView that queries OpenAgents.Repo instead of a context"
      )
    end

    test "the enumeration covers every LiveView the router serves" do
      routed = MapSet.new(live_routes(), fn {_verb, _path, view, _session} -> view end)
      compiled = MapSet.new(live_views())

      assert MapSet.difference(routed, compiled) |> MapSet.to_list() == [],
             "a routed LiveView was not read from the compiled module list"

      assert MapSet.size(routed) >= 40
    end
  end

  # ── population ──────────────────────────────────────────────────────────

  defp live_routes do
    for route <- OpenAgentsWeb.Router.__routes__(), route.plug == Phoenix.LiveView.Plug do
      {view, _action, _options, session} = route.metadata[:phoenix_live_view]
      {to_string(route.verb), route.path, view, session}
    end
  end

  defp route_classes do
    RouteAuthority.inventory()
    |> Enum.filter(&(&1.transport == :http))
    |> Map.new(&{{&1.verb, &1.path}, &1.class})
  end

  defp live_views do
    {:ok, modules} = :application.get_key(:openagents, :modules)
    Enum.each(modules, &Code.ensure_loaded/1)
    Enum.filter(modules, &function_exported?(&1, :__live__, 0))
  end

  # Read from the compiled import table rather than from source text, so a
  # comment cannot add a query and an alias cannot hide one.
  defp reaches_repo?(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
      Enum.any?(imports, fn {called, _function, _arity} -> called == OpenAgents.Repo end)
    else
      _unreadable -> false
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp login(user), do: Plug.Test.init_test_session(build_conn(), %{"user_id" => user.id})

  defp assert_exact_set(actual, declared, what) do
    actual = MapSet.new(actual)
    declared = MapSet.new(declared)

    assert MapSet.difference(actual, declared) |> MapSet.to_list() == [],
           """
           Something that #{what} is not named in
           test/openagents_web/live_view_scope_test.exs. Amend IDENTITY-002 in
           INVARIANTS.md, then add it here.
           """

    assert MapSet.difference(declared, actual) |> MapSet.to_list() == [],
           """
           This test names something that no longer #{what}. Amend IDENTITY-002
           in INVARIANTS.md, then remove it here.
           """
  end
end
