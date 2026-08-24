defmodule OpenAgents.Forge.ExitRehearsalRunbookTest do
  @moduledoc """
  #189's third acceptance criterion. Rehearsal 3's step 3 told an operator to
  run `OpenAgents.Forge.Sync.rebuild/1` before that function existed, and no
  invariant could notice: invariants read compiled modules, and the procedure
  was a string in a Markdown file. This test reads the strings.

  Three shapes of reference in `docs/forge-exit-rehearsals.md` are checked
  against the compiled code:

  - every `bin/openagents rpc '…'` command in any document under `docs/`
    parses as Elixir, and every `OpenAgents` function it calls is exported at
    the called arity;
  - every qualified `OpenAgents.Module.function/arity` reference resolves;
  - every bare `function/arity` reference in code font is exported by at
    least one module the document names.

  A renamed or removed function now turns this test red instead of leaving a
  runbook step that reads as executable but is not.
  """

  use ExUnit.Case, async: true

  @runbook "docs/forge-exit-rehearsals.md"

  test "every rpc command in the documentation calls functions that exist" do
    commands =
      for path <- Path.wildcard("docs/**/*.md"),
          [command] <-
            Regex.scan(~r{bin/openagents rpc '([^']+)'}, File.read!(path),
              capture: :all_but_first
            ),
          do: {path, command}

    assert Enum.any?(commands, fn {path, _command} -> path == @runbook end),
           "#{@runbook} no longer contains rpc commands; retire this test"

    for {path, command} <- commands do
      calls =
        command
        |> Code.string_to_quoted!()
        |> expand_pipes()
        |> collect_openagents_calls()

      assert calls != [], "rpc command in #{path} calls no OpenAgents function: #{command}"

      for {module, function, arity} <- calls do
        assert Code.ensure_loaded?(module),
               "#{inspect(module)} is named in #{path} but does not exist"

        assert function_exported?(module, function, arity),
               "#{inspect(module)}.#{function}/#{arity} is named in #{path} " <>
                 "but is not exported at that arity"
      end
    end
  end

  test "every qualified function/arity reference in the runbook resolves" do
    references =
      Regex.scan(
        ~r/(OpenAgents(?:\.[A-Z][A-Za-z0-9_]*)+)\.([a-z_][a-z0-9_]*[?!]?)\/(\d+)/,
        runbook(),
        capture: :all_but_first
      )

    for [module_name, function, arity] <- references do
      module = Module.concat([module_name])
      function = String.to_atom(function)
      arity = String.to_integer(arity)

      assert Code.ensure_loaded?(module),
             "#{module_name} is named in #{@runbook} but does not exist"

      assert function_exported?(module, function, arity),
             "#{module_name}.#{function}/#{arity} is named in #{@runbook} but is not exported"
    end
  end

  test "every module the runbook names exists" do
    modules = named_modules()

    assert OpenAgents.Forge.Sync in modules

    for module <- modules do
      assert Code.ensure_loaded?(module),
             "#{inspect(module)} is named in #{@runbook} but does not exist"
    end
  end

  test "every bare function/arity reference is exported by a module the runbook names" do
    # `function_exported?/3` does not load a module, so load them first. The
    # modules-exist test owns the assertion that loading never fails.
    modules = Enum.filter(named_modules(), &Code.ensure_loaded?/1)

    references =
      Regex.scan(~r/`([a-z_][a-z0-9_]*[?!]?)\/(\d+)`/, runbook(), capture: :all_but_first)

    # The reference this test exists for. Its absence means the document
    # changed shape, not that the check passed.
    assert ["rebuild", "1"] in references

    for [function, arity] <- references do
      # Document content is repository-controlled, so minting the atom here
      # is bounded by what review admits into the runbook.
      function = String.to_atom(function)
      arity = String.to_integer(arity)

      assert Enum.any?(modules, &function_exported?(&1, function, arity)),
             "`#{function}/#{arity}` is named in #{@runbook} but no module " <>
               "the document names exports it"
    end
  end

  defp runbook, do: File.read!(@runbook)

  defp named_modules do
    Regex.scan(~r/OpenAgents(?:\.[A-Z][A-Za-z0-9_]*)+/, runbook())
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.map(&Module.concat([&1]))
  end

  # `verify(…) |> IO.inspect()` calls `IO.inspect/1`, not `IO.inspect/0`, so
  # pipes are rewritten into ordinary calls before arities are read.
  defp expand_pipes(ast) do
    Macro.prewalk(ast, fn
      {:|>, _, [_, _]} = pipe ->
        [{first, _} | rest] = Macro.unpipe(pipe)

        Enum.reduce(rest, first, fn {call, position}, piped ->
          Macro.pipe(piped, call, position)
        end)

      node ->
        node
    end)
  end

  defp collect_openagents_calls(ast) do
    {_, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:OpenAgents | _] = parts}, function]}, _, args} = node, acc
        when is_list(args) ->
          {node, [{Module.concat(parts), function, length(args)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end
end
