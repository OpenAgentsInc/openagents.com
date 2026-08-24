defmodule OpenAgentsWeb.TransparencySurfaceTest do
  @moduledoc """
  The executable enumeration behind TRANSPARENCY-001.

  TRANSPARENCY-001 states bounds that hold "at every level" and then lists the
  surfaces it is about by hand: `/changelog`, `/api/changelog`, and three forge
  paths. `OpenAgents.Forge.VisibilityTest` proves the dial answers correctly and
  `OpenAgents.Forge.BrowseTest` proves the reads are bounded; neither can fail
  for a public surface nobody added to the list. When this file was written the
  router already served ten anonymous routes under `/:owner/:repo`, and
  `/:owner/:repo/tree/:ref/*path` — the directory listing — was not one of the
  three the contract named.

  So the surfaces are taken from the router rather than from the sentence.
  `OpenAgentsWeb.RouteAuthority` classifies every route, `route_authority_test.exs`
  already fails a route it cannot classify, and every anonymous route under the
  repository scope is partitioned here into the two gates the application
  actually has:

    * `:disclosure_level` — repository *content*, gated by
      `OpenAgentsWeb.RepositoryAccess`, which is the only composer of
      `OpenAgents.Forge.Visibility`'s per-repo dial for the web surfaces.
    * `:repository_readability` — the issue tracker, gated by
      `OpenAgents.Repositories.get_visible_by_path!/3`. Issues, labels,
      milestones, projects, and the pull-request index are readable exactly when
      the repository is; the disclosure dial governs source and history, not
      them.

  A route added under `/:owner/:repo` fails here until TRANSPARENCY-001 says
  which gate it is behind, and a handler that loses its gate fails with it. The
  gate memberships are read from compiled import tables, so an alias cannot
  disguise one and a comment cannot add one.
  """

  use ExUnit.Case, async: true

  alias OpenAgentsWeb.RouteAuthority

  # Every anonymous route under the repository scope, with the gate it is
  # behind. TRANSPARENCY-001 names each.
  @repository_surfaces %{
    {"get", "/:owner/:repo"} => :disclosure_level,
    {"get", "/:owner/:repo/commit/:sha"} => :disclosure_level,
    {"get", "/:owner/:repo/tree/:ref/*path"} => :disclosure_level,
    {"get", "/:owner/:repo/blob/:ref/*path"} => :disclosure_level,
    {"get", "/:owner/:repo/pulls/:number"} => :disclosure_level,
    {"get", "/:owner/:repo/issues"} => :repository_readability,
    {"get", "/:owner/:repo/issues/:number"} => :repository_readability,
    {"get", "/:owner/:repo/labels"} => :repository_readability,
    {"get", "/:owner/:repo/milestones"} => :repository_readability,
    {"get", "/:owner/:repo/projects"} => :repository_readability,
    {"get", "/:owner/:repo/projects/:number"} => :repository_readability,
    {"get", "/:owner/:repo/pulls"} => :repository_readability
  }

  # The two receipt-chain surfaces, which publish the changelog projection
  # rather than repository content.
  @changelog_surfaces %{
    {"get", "/changelog"} => OpenAgentsWeb.ChangelogLive,
    {"get", "/api/changelog"} => OpenAgentsWeb.ChangelogController
  }

  # Every module that reads the per-repo disclosure dial, and what it decides.
  @visibility_readers %{
    OpenAgents.Changelog => "levels and embargoes a published changelog entry",
    OpenAgents.Reputation => "levels a published attestation",
    OpenAgents.Settlement => "levels a published settlement record",
    OpenAgentsWeb.ChangelogLive => "renders the leveled timeline",
    OpenAgentsWeb.RepositoryAccess => "composes the dial for every web repository surface"
  }

  @gate_dependency %{
    disclosure_level: {OpenAgentsWeb.RepositoryAccess, :any},
    repository_readability: {OpenAgents.Repositories, :get_visible_by_path!}
  }

  test "the anonymous repository surfaces are exactly the ones TRANSPARENCY-001 names" do
    actual = MapSet.new(Map.keys(repository_routes()))
    declared = MapSet.new(Map.keys(@repository_surfaces))

    assert MapSet.difference(actual, declared) |> MapSet.to_list() == [],
           """
           An anonymous route under `/:owner/:repo` reached the router that
           TRANSPARENCY-001 does not name. Every one of them publishes something
           about a repository to a caller with no session. Amend
           TRANSPARENCY-001 in INVARIANTS.md, then add it here with its gate.
           """

    assert MapSet.difference(declared, actual) |> MapSet.to_list() == [],
           """
           TRANSPARENCY-001 names an anonymous repository route the router no
           longer serves. Amend TRANSPARENCY-001 in INVARIANTS.md, then remove
           it here.
           """
  end

  test "every anonymous repository surface reaches the gate its class names" do
    routes = repository_routes()

    for {route, gate} <- @repository_surfaces do
      handler = Map.fetch!(routes, route)
      {module, function} = Map.fetch!(@gate_dependency, gate)

      assert names?(handler, module, function), """
      #{inspect(handler)} serves #{elem(route, 1)} without reaching #{inspect(module)}.

      TRANSPARENCY-001 puts that route behind the #{gate} gate. A public
      repository surface with no gate publishes a private repository's content
      to anyone. Restore the gate, or amend TRANSPARENCY-001 and move the route
      to the other class here.
      """
    end
  end

  test "the receipt-chain surfaces publish through the leveled changelog projection" do
    routes = Map.new(RouteAuthority.inventory(), &{{&1.verb, &1.path}, &1})

    for {route, handler} <- @changelog_surfaces do
      entry = Map.fetch!(routes, route)
      assert entry.class == :public_read

      assert names?(handler, OpenAgents.Changelog, :any), """
      #{inspect(handler)} serves #{elem(route, 1)} without reaching
      `OpenAgents.Changelog`, which is where the per-repo level and the
      security embargo are applied.
      """
    end
  end

  test "the modules that read the disclosure dial are exactly the set TRANSPARENCY-001 accounts for" do
    actual = MapSet.new(callers(&(elem(&1, 0) == OpenAgents.Forge.Visibility)))
    declared = @visibility_readers |> Map.keys() |> MapSet.new()

    assert MapSet.difference(actual, declared) |> MapSet.to_list() == [],
           """
           A module gained a dependency on the per-repo disclosure dial without
           TRANSPARENCY-001 accounting for it. The dial decides what a repository
           publishes below `:l3`, so a second reader is a second policy. Amend
           TRANSPARENCY-001 in INVARIANTS.md, then add it here with what it
           decides.
           """

    assert MapSet.difference(declared, actual) |> MapSet.to_list() == [],
           """
           TRANSPARENCY-001 accounts for a reader of the disclosure dial that no
           longer exists. Amend TRANSPARENCY-001 in INVARIANTS.md, then remove
           it here.
           """
  end

  # Anonymous routes under the repository scope, as {verb, path} => handler.
  defp repository_routes do
    handlers =
      Map.new(OpenAgentsWeb.Router.__routes__(), fn route ->
        {{to_string(route.verb), route.path}, Map.get(route.metadata, :log_module) || route.plug}
      end)

    for entry <- RouteAuthority.inventory(),
        entry.class == :public_read,
        String.starts_with?(entry.path, "/:owner/:repo"),
        into: %{},
        do: {{entry.verb, entry.path}, Map.fetch!(handlers, {entry.verb, entry.path})}
  end

  defp names?(module, target, function) do
    Enum.any?(imports(module), fn
      {^target, name, _arity} -> function == :any or name == function
      _other -> false
    end)
  end

  # Read from each compiled module's import table rather than from source text,
  # so a comment cannot add a caller and a rename cannot hide one.
  defp callers(predicate) do
    {:ok, modules} = :application.get_key(:openagents, :modules)

    modules
    |> Enum.filter(&Enum.any?(imports(&1), predicate))
    |> Enum.sort()
  end

  defp imports(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
      imports
    else
      _unreadable -> []
    end
  end
end
