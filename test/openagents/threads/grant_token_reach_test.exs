defmodule OpenAgents.Threads.GrantTokenReachTest do
  @moduledoc """
  The executable enumeration behind THREAD-001's token clause.

  THREAD-001 says no route returns a grant token for a thread the caller did
  not open, and the token is returned exactly once, at the mint.
  `OpenAgentsWeb.ThreadControllerTest` proves both at the three routes that
  exist, which is a proof of those routes rather than of the sentence: a second
  route that renders a grant would pass every test in this repository.

  So the population is enumerated instead of sampled. A plaintext grant token
  comes into existence in exactly one place, `OpenAgents.Inference.mint/1`, and
  leaves `OpenAgents.Threads` through exactly the exports named below. Every
  module that can hold one therefore carries a compiled import edge to one of
  those functions, and the edges are read from each module's BEAM import table
  rather than from source text, so a comment cannot add a caller and a rename
  cannot hide one.

  Four sets close it:

  1. the modules that mint a token,
  2. the modules that receive one from a thread,
  3. the routed handlers in either set, which must be the one controller that
     serves the mint,
  4. `OpenAgents.Threads`'s own export table, so a new function that hands a
     caller a token is classified here before anything can call it.

  The fifth test dispatches every route the router gives that controller and
  requires the body to carry a token only at the mint. It derives the route set
  from `OpenAgentsWeb.Router.__routes__/0`, so a fourth thread route is
  dispatched by this test the day it lands.
  """

  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Threads

  # Every module whose import table names `OpenAgents.Inference.mint/1`, with
  # what it does with the plaintext token the mint returns.
  @token_minters %{
    OpenAgents.Threads => "returns it to the caller of mint_grant/1 and open_and_mint/3",
    OpenAgents.Work.Coding => "discards it; the meter is internal and nothing redeems it",
    OpenAgents.Work.DelegationServer => "injects it into the probe process it spawns",
    OpenAgents.Work.Scv => "discards it; the meter is internal and nothing redeems it"
  }

  # `OpenAgents.Threads`'s exports, each classified by what it can hand a
  # caller. A new export fails this until it is named here, which is where
  # someone has to answer whether it returns a token or resolves a thread.
  @threads_api %{
    {:active_grants, 1} => :thread_struct,
    {:cancel, 1} => :thread_struct,
    {:cancel, 2} => :thread_struct,
    {:ceilings, 0} => :no_thread,
    {:ceilings, 1} => :no_thread,
    {:default_permission_profile, 0} => :no_thread,
    {:default_reasoning, 0} => :no_thread,
    {:finish, 2} => :thread_struct,
    {:get_for_user, 2} => :scoped_by_owner,
    {:latest_grant, 1} => :thread_struct,
    {:list_events, 1} => :thread_struct,
    {:list_events, 2} => :thread_struct,
    {:list_for_user, 1} => :scoped_by_owner,
    {:list_for_user, 2} => :scoped_by_owner,
    {:maximum_open_per_account, 0} => :no_thread,
    {:mint_grant, 1} => :returns_plaintext_token,
    {:open, 2} => :scoped_by_owner,
    {:open, 3} => :scoped_by_owner,
    {:open_and_mint, 2} => :returns_plaintext_token,
    {:open_and_mint, 3} => :returns_plaintext_token,
    {:open_count, 1} => :scoped_by_owner,
    {:reap_expired, 1} => :scoped_by_owner,
    {:record_event, 3} => :thread_struct
  }

  # Every module that reaches a token-returning `OpenAgents.Threads` export.
  # One controller, serving one route: the mint.
  @grant_token_holders [OpenAgentsWeb.ThreadController]

  # The one function that resolves a thread from an identifier, and every
  # module that calls it. It takes the acting account, so another account's
  # thread id resolves to `nil` (THREAD-001, IDENTITY-002).
  @thread_resolver_callers [OpenAgentsWeb.ThreadController]

  test "the modules that mint a grant token are exactly the set THREAD-001 accounts for" do
    assert_exact_set(
      callers_of([{OpenAgents.Inference, :mint, 1}]),
      Map.keys(@token_minters),
      "mints a grant token"
    )
  end

  test "the exports of OpenAgents.Threads are exactly the ones classified here" do
    actual = Threads.__info__(:functions) |> Enum.reject(fn {name, _} -> name == :__struct__ end)

    assert_exact_set(
      actual,
      Map.keys(@threads_api),
      "is an OpenAgents.Threads export; classify whether it returns a plaintext token"
    )
  end

  test "the modules that receive a thread's grant token are exactly the ones named" do
    assert token_returning() != []

    assert_exact_set(
      callers_of(token_returning()),
      @grant_token_holders,
      "holds a plaintext grant token"
    )
  end

  test "the only routed handler that can hold a grant token serves the mint" do
    holders = MapSet.new(callers_of([{OpenAgents.Inference, :mint, 1} | token_returning()]))

    routed =
      OpenAgentsWeb.Router.__routes__()
      |> MapSet.new(& &1.plug)
      |> MapSet.intersection(holders)

    assert MapSet.to_list(routed) == [OpenAgentsWeb.ThreadController],
           """
           A routed handler other than the thread mint can hold a plaintext
           grant token. THREAD-001 says no other route returns one.
           """
  end

  test "a thread resolves by identifier only through the owner-scoped lookup" do
    resolvers = for {key, :scoped_by_owner} <- @threads_api, do: key
    assert {:get_for_user, 2} in resolvers

    assert_exact_set(
      callers_of([{OpenAgents.Threads, :get_for_user, 2}]),
      @thread_resolver_callers,
      "resolves a thread by identifier"
    )
  end

  test "every route the router gives the thread controller returns a token only at the mint" do
    conn = put_chat_api_token(build_conn(), "grant-token-reach")

    created =
      conn
      |> post(~p"/api/v3/threads", %{"objective" => "Count the doors that hand out authority."})
      |> json_response(201)

    thread_id = created["thread"]["id"]
    assert is_binary(created["grant"]["token"])

    routes =
      Enum.filter(OpenAgentsWeb.Router.__routes__(), &(&1.plug == OpenAgentsWeb.ThreadController))

    assert length(routes) >= 3

    for route <- routes, route.plug_opts != :create do
      path = String.replace(route.path, ":thread_id", thread_id)
      body = conn |> dispatch_route(route.verb, path) |> json_response(200)

      refute token?(body),
             """
             #{route.verb |> to_string() |> String.upcase()} #{route.path} returned a grant
             token. THREAD-001 says the token is returned exactly once, at the mint.
             """
    end
  end

  # The `OpenAgents.Threads` exports that hand a caller the plaintext token,
  # derived from the classification above rather than listed twice.
  defp token_returning do
    for {{name, arity}, :returns_plaintext_token} <- @threads_api,
        do: {OpenAgents.Threads, name, arity}
  end

  defp dispatch_route(conn, :get, path), do: get(conn, path)
  defp dispatch_route(conn, :delete, path), do: delete(conn, path)
  defp dispatch_route(conn, :post, path), do: post(conn, path, %{})

  # A token is a value, not a key: a response that renamed the field would
  # still be caught, because the plaintext carries the mint's prefix.
  defp token?(value) when is_binary(value), do: String.starts_with?(value, "sig_")
  defp token?(value) when is_map(value), do: value |> Map.values() |> Enum.any?(&token?/1)
  defp token?(value) when is_list(value), do: Enum.any?(value, &token?/1)
  defp token?(_value), do: false

  # Read from each compiled module's import table rather than from source text.
  defp callers_of(mfas) do
    wanted = MapSet.new(mfas)
    {:ok, modules} = :application.get_key(:openagents, :modules)

    Enum.filter(modules, fn module ->
      with path when is_list(path) <- :code.which(module),
           {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
        Enum.any?(imports, &MapSet.member?(wanted, &1))
      else
        _unreadable -> false
      end
    end)
  end

  defp assert_exact_set(actual, declared, what) do
    actual = MapSet.new(actual)
    declared = MapSet.new(declared)

    assert MapSet.difference(actual, declared) |> MapSet.to_list() == [],
           """
           Something that #{what} is not named in
           test/openagents/threads/grant_token_reach_test.exs. Amend THREAD-001
           in INVARIANTS.md, then add it here.
           """

    assert MapSet.difference(declared, actual) |> MapSet.to_list() == [],
           """
           This test names something that no longer #{what}. Amend THREAD-001
           in INVARIANTS.md, then remove it here.
           """
  end
end
