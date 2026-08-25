defmodule OpenAgents.DependencyBoundaryTest do
  @moduledoc """
  The shared enumeration behind five claims of the same shape.

  Each of these invariants says that *every* surface reaches something through
  one chokepoint, or that *no* surface reaches something at all:

    * `PROVIDER-001` — conversation and web code depend on the provider
      behaviour, never on the OpenAI adapter.
    * `SELF-EDIT-001` — no OpenAgents tool can promote, deploy, or hot-load.
    * `SCV-001` — every surface that starts an SCV enters
      `OpenAgents.SCV.Deployments.start/2`.
    * `FLEETPROMOTE-001` — the **Promote** button and the operator API are one
      authority path, not two implementations of one policy.
    * `TOOL-005` — every surface that builds a model-facing catalog resolves
      the caller for the turn.

  Tests of the surfaces someone remembered cannot fail on the surface they did
  not, so each claim was previously proven by behaviour at the chokepoint while
  asserting something about everything that reaches it. This file proves the
  quantifier instead: it reads every compiled module's import table and
  compares the set of modules that cross each boundary against a set this
  ledger declares. A module that gains the dependency fails here until an
  invariant names it.

  Import tables are read rather than source text, so a comment cannot add a
  caller, a rename cannot hide one, and an alias cannot disguise one. A module
  reached only through configuration — the way `OpenAgents.Providers.OpenAI`
  itself is reached — carries no import edge, which is the property
  `PROVIDER-001` is about.
  """

  use ExUnit.Case, async: true

  # PROVIDER-001. The adapter is selected by configuration and called through
  # `OpenAgents.Providers.Provider`, so no module should name it or any module
  # beneath it. The adapter's own submodules are the only admitted crossing.
  @openai_adapter_namespace "Elixir.OpenAgents.Providers.OpenAI"
  @openai_adapter_callers [OpenAgents.Providers.OpenAI]

  # SELF-EDIT-001. Promotion, deployment, and hot-loading are operator actions.
  # No tool a model can call may reach any of them.
  @fleet_release_modules [
    OpenAgents.Forge.Deployment,
    OpenAgents.Forge.HotLoader,
    OpenAgents.Forge.Promotion,
    OpenAgents.Forge.RelupDeployment,
    OpenAgents.Forge.RollingReplacement,
    OpenAgents.Forge.Targets
  ]

  # SCV-001. `OpenAgents.SCV.Deployments.start/2` refuses a non-operator before
  # a row is written, and `OpenAgents.Work.start_scv/1` is what it calls once
  # admitted. A second caller of `start_scv/1` would be an SCV that skipped
  # admission.
  @scv_start_callers [OpenAgents.SCV.Deployments]

  # FLEETPROMOTE-001. Both promotion surfaces call `OpenAgents.Forge.Promotion`,
  # which is the only caller of `OpenAgents.Forge.Targets.promote/4`.
  @promotion_callers [OpenAgentsWeb.AdminForgeLive, OpenAgentsWeb.FleetTargetController]
  @target_promote_callers [OpenAgents.Forge.Promotion]

  # TOOL-005. `OpenAgents.Tools.Selector` ranks a model-facing catalog, and
  # `OpenAgents.Tools.Selector.reachable/2` narrows nothing when it is given no
  # caller. A module that ranks a catalog without also naming
  # `OpenAgents.Tools.Reach` would therefore offer tools the caller cannot use.
  @catalog_builders [OpenAgents.Tools.AdmittedCatalog, OpenAgents.Tools.Registry]

  describe "PROVIDER-001" do
    test "nothing outside the OpenAI adapter calls into it" do
      callers =
        callers(fn {module, _function, _arity} ->
          String.starts_with?(Atom.to_string(module), @openai_adapter_namespace)
        end)

      assert_exactly(callers, @openai_adapter_callers, """
      A module gained a compile-time dependency on the OpenAI adapter.

      PROVIDER-001 says conversation and web code depend on
      `OpenAgents.Providers.Provider`, not on OpenAI event shapes. Route the
      call through the behaviour, or amend PROVIDER-001 and name the module
      here.
      """)
    end
  end

  describe "SELF-EDIT-001" do
    test "no tool module reaches fleet promotion, deployment, or hot-loading" do
      offenders =
        callers(fn {module, _function, _arity} -> module in @fleet_release_modules end)
        |> Enum.filter(&tool_module?/1)

      assert offenders == [], """
      A tool gained a compile-time dependency on the fleet release path:

      #{Enum.map_join(offenders, "\n", &"  #{inspect(&1)}")}

      SELF-EDIT-001 says no OpenAgents tool can promote, deploy, or hot-load.
      Promotion is an operator action; the job's report links the pushed SHA
      and a person clicks **Promote**.
      """
    end
  end

  describe "SCV-001" do
    test "the SCV worker is started only from the admission gate" do
      callers =
        callers(fn {module, function, _arity} ->
          module == OpenAgents.Work and function == :start_scv
        end)

      assert_exactly(callers, @scv_start_callers, """
      A module can start an SCV without entering
      `OpenAgents.SCV.Deployments.start/2`.

      SCV-001 says every surface that starts an SCV enters that function,
      because it is where a non-operator is refused before a row is written or
      a process is spawned. Call it instead, or amend SCV-001.
      """)
    end
  end

  describe "FLEETPROMOTE-001" do
    test "both promotion surfaces reach one implementation of the policy" do
      callers =
        callers(fn {module, _function, _arity} -> module == OpenAgents.Forge.Promotion end)

      assert_exactly(callers, @promotion_callers, """
      A surface gained the ability to promote a fleet target.

      FLEETPROMOTE-001 names the `/admin/forge` **Promote** button and
      `POST /api/v1/admin/forge/targets` as one authority path. A third surface
      must be named there before it is added here.
      """)
    end

    test "the promotion policy is the only caller of the target writer" do
      callers =
        callers(fn {module, function, _arity} ->
          module == OpenAgents.Forge.Targets and function == :promote
        end)

      assert_exactly(callers, @target_promote_callers, """
      A module writes a fleet promotion receipt without passing through
      `OpenAgents.Forge.Promotion`, so it does not apply the scope check, the
      live operator standing check, or the idempotency rules
      FLEETPROMOTE-001 states.
      """)
    end
  end

  describe "TOOL-005" do
    test "every module that ranks a catalog also resolves the caller" do
      selector_callers =
        callers(fn {module, _function, _arity} -> module == OpenAgents.Tools.Selector end)

      assert_exactly(selector_callers, @catalog_builders, """
      A module ranks a model-facing catalog that TOOL-005 does not name.

      `OpenAgents.Tools.Selector` narrows nothing when it is given no caller,
      so a new catalog builder offers tools the caller cannot reach and every
      existing test stays green. Amend TOOL-005, then name the module here.
      """)

      reach_callers =
        MapSet.new(
          callers(fn {module, _function, _arity} -> module == OpenAgents.Tools.Reach end)
        )

      for builder <- selector_callers do
        assert MapSet.member?(reach_callers, builder), """
        #{inspect(builder)} ranks a model-facing catalog without naming
        `OpenAgents.Tools.Reach`, so the selector receives no caller and drops
        no unreachable tool. TOOL-005 requires the caller to be resolved once
        for the turn before ranking.
        """
      end
    end
  end

  defp assert_exactly(actual, declared, message) do
    actual = MapSet.new(actual)
    declared = MapSet.new(declared)

    undeclared = actual |> MapSet.difference(declared) |> MapSet.to_list()
    stale = declared |> MapSet.difference(actual) |> MapSet.to_list()

    assert undeclared == [],
           message <> "\nUndeclared:\n" <> Enum.map_join(undeclared, "\n", &"  #{inspect(&1)}")

    assert stale == [],
           "This file names a dependency that no longer exists. Remove it.\n" <>
             "\nStale:\n" <> Enum.map_join(stale, "\n", &"  #{inspect(&1)}")
  end

  defp tool_module?(module) do
    String.starts_with?(Atom.to_string(module), "Elixir.OpenAgents.Tools.")
  end

  # Read from each compiled module's import table rather than from source text,
  # so a comment cannot add a caller and a rename cannot hide one.
  defp callers(predicate) do
    {:ok, modules} = :application.get_key(:openagents, :modules)

    modules
    |> Enum.filter(fn module ->
      with path when is_list(path) <- :code.which(module),
           {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
        Enum.any?(imports, predicate)
      else
        _unreadable -> false
      end
    end)
    |> Enum.sort()
  end
end
