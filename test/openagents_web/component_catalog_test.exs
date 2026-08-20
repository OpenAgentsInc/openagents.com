defmodule OpenAgentsWeb.ComponentCatalogTest do
  @moduledoc """
  Guards the catalog against silently falling behind the code.

  The catalog was originally hand-written and drifted: nineteen SarahUI
  components shipped without ever appearing on the components page. This test
  makes that failure mode loud — adding a public function component to a
  documented module fails the suite until it is catalogued or explicitly
  excluded.
  """

  use ExUnit.Case, async: true

  alias OpenAgentsWeb.ComponentCatalog

  test "slugs are unique" do
    slugs = ComponentCatalog.slugs()
    assert length(slugs) == length(Enum.uniq(slugs))
  end

  test "every catalog entry names a module and function that actually exist" do
    for item <- ComponentCatalog.items() do
      {module, function} = parse_source(item.source)

      assert Code.ensure_loaded?(module),
             "#{item.slug} names a module that does not exist: #{inspect(module)}"

      assert function_exported?(module, function, 1),
             "#{item.slug} names #{inspect(module)}.#{function}/1, which is not exported"
    end
  end

  test "the catalog covers every public function component in the documented modules" do
    for {module, excluded} <- ComponentCatalog.documented_modules() do
      catalogued =
        ComponentCatalog.items()
        |> Enum.map(&parse_source(&1.source))
        |> Enum.filter(fn {m, _f} -> m == module end)
        |> Enum.map(fn {_m, f} -> f end)
        |> MapSet.new()

      missing =
        module
        |> function_components()
        |> Enum.reject(&(&1 in excluded))
        |> Enum.reject(&(&1 in catalogued))

      assert missing == [],
             """
             #{inspect(module)} has public function components with no catalog entry:
             #{inspect(missing)}

             Add them to OpenAgentsWeb.ComponentCatalog with a matching
             component_demo/1 clause in OpenAgentsWeb.ComponentsLive, or add them
             to the exclusion list in ComponentCatalog.documented_modules/0 with a
             reason.
             """
    end
  end

  # `__components__/0` registers every component the compiler saw attrs for,
  # including `defp` ones (Layouts.openagents_command_bar/1 is private). A
  # private component cannot be called from a catalog page, so intersect with
  # the module's actual exports rather than carrying dead exclusion entries.
  defp function_components(module) do
    Code.ensure_loaded!(module)

    exported =
      module.__info__(:functions)
      |> Enum.filter(fn {_name, arity} -> arity == 1 end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    if function_exported?(module, :__components__, 0) do
      module.__components__()
      |> Map.keys()
      |> Enum.filter(&(&1 in exported))
      |> Enum.sort()
    else
      exported
      |> Enum.reject(&String.starts_with?(Atom.to_string(&1), "__"))
      |> Enum.sort()
    end
  end

  defp parse_source(source) do
    [path, arity_part] = String.split(source, "/", parts: 2)
    ^arity_part = "1"

    segments = String.split(path, ".")
    {function, module_segments} = List.pop_at(segments, -1)

    {Module.concat(module_segments), String.to_atom(function)}
  end
end
