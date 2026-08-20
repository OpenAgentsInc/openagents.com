defmodule OpenAgentsWeb.ComponentAttrsTest do
  @moduledoc """
  Every enumerated component attribute states the values it accepts.

  Phoenix checks a literal attribute at a call site only when the declaration
  carries a `values:` list. Without one it accepts anything, and the failure is
  silent all the way to the browser: `UI.github_login/1` declared
  `attr :size, :atom, default: :md`, `:md` is not one of `button/1`'s sizes, so
  the button rendered `data-size="md"`, matched no size rule, and arrived with
  no height, no padding and no type scale. Nothing warned, no test failed, and
  the control simply looked wrong.

  The rule is narrow and mechanical: an `:atom` attribute is an enumeration, so
  it must say what it enumerates. That is enough to hand the problem to the
  compiler, which then rejects a bad call site by name — and it did
  immediately, catching `graph_node/1` being passed work-item statuses its
  declaration did not admit.

  `:string`, `:boolean`, `:map`, `:list`, `:any` and `:global` are unbounded by
  nature and are not checked.
  """

  use ExUnit.Case, async: true

  # `attr` declarations wrap, so the options are read up to the next `attr`,
  # `slot`, `def`, or blank-line boundary rather than to the end of the line.
  @declaration ~r/^[ \t]*attr :(\w+), :atom\b(?<options>(?:.|\n)*?)(?=\n[ \t]*(?:attr |slot |def |defp |@doc|\n))/m

  test "every atom attribute declares the values it accepts" do
    offenders =
      for path <- component_sources(),
          source = File.read!(path),
          match <- Regex.scan(@declaration, source, capture: :all_but_first, return: :index),
          {offender, line} <- offense(source, match),
          do: {relative(path), line, offender}

    assert offenders == [], """
    These `:atom` attributes do not declare a `values:` list, so Phoenix cannot
    check what call sites pass them and a wrong value fails silently in the
    browser rather than loudly at compile time:

    #{Enum.map_join(offenders, "\n", fn {file, line, name} -> "  #{file}:#{line}  attr :#{name}" end)}

    Add `values: [...]`. If the attribute genuinely accepts any atom, it is not
    an enumeration -- declare it as `:any` and say why in a comment.
    """
  end

  defp offense(source, [{name_start, name_length}, {options_start, options_length}]) do
    name = binary_part(source, name_start, name_length)
    options = binary_part(source, options_start, options_length)

    if String.contains?(options, "values:") do
      []
    else
      [{name, line_of(source, name_start)}]
    end
  end

  defp offense(_source, _match), do: []

  defp component_sources do
    Path.wildcard("lib/openagents_web/**/*.ex")
  end

  defp line_of(source, offset),
    do: source |> binary_part(0, offset) |> String.split("\n") |> length()

  defp relative(path), do: String.replace_leading(path, "lib/openagents_web/", "")
end
