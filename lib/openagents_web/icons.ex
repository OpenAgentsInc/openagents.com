defmodule OpenAgentsWeb.Icons do
  @moduledoc """
  The vendored icon set, embedded at compile time.

  Files under `priv/icons` are produced from
  [openai/apps-sdk-ui](https://github.com/openai/apps-sdk-ui) and are never
  hand-edited. See `priv/icons/README.md` and `priv/icons/LICENSE`.

  Each glyph is stored as a complete standalone SVG so the file stays viewable
  and diffable on its own. This module splits it into the viewBox and the inner
  markup so `OpenAgentsWeb.UI.icon/1` can render a fresh root element
  with the accessibility and sizing attributes the call site needs.
  """

  @icons_dir Path.join([__DIR__, "..", "..", "priv", "icons"]) |> Path.expand()

  # Brand marks live apart from the vendored set: a logo can never come from a
  # generic icon library. They are namespaced `brand-*`. See priv/brand/README.md.
  @brand_dir Path.join([__DIR__, "..", "..", "priv", "brand"]) |> Path.expand()

  # Issue-state glyphs from Primer Octicons. See priv/octicons/README.md.
  @octicons_dir Path.join([__DIR__, "..", "..", "priv", "octicons"]) |> Path.expand()

  @paths (@icons_dir |> Path.join("*.svg") |> Path.wildcard()) ++
           (@brand_dir |> Path.join("*.svg") |> Path.wildcard()) ++
           (@octicons_dir |> Path.join("*.svg") |> Path.wildcard())

  for path <- @paths do
    @external_resource path
  end

  @icons Map.new(@paths, fn path ->
           base = Path.basename(path, ".svg")

           name =
             cond do
               Path.dirname(path) == @brand_dir -> "brand-" <> base
               Path.dirname(path) == @octicons_dir -> "octicon-" <> base
               true -> base
             end

           contents = path |> File.read!() |> String.trim()

           view_box =
             case Regex.run(~r/viewBox="([^"]+)"/, contents) do
               [_, value] -> value
               _ -> raise "#{path} has no viewBox"
             end

           inner =
             case Regex.run(~r|<svg\b[^>]*>(.*)</svg>|s, contents) do
               [_, markup] -> String.trim(markup)
               _ -> raise "#{path} is not a single <svg> element"
             end

           {name, {view_box, inner}}
         end)

  if map_size(@icons) == 0 do
    raise "no icons found in #{@icons_dir}. Run: mix openagents.icons.vendor <path-to-apps-sdk-ui>"
  end

  @names @icons |> Map.keys() |> Enum.sort()

  @doc "Every vendored icon name, sorted."
  def names, do: @names

  @doc "How many glyphs are vendored."
  def count, do: length(@names)

  @doc "Whether a glyph exists."
  def exists?(name) when is_binary(name), do: Map.has_key?(@icons, name)

  @doc """
  The `{view_box, inner_markup}` for one glyph.

  Raises on an unknown name rather than rendering an empty box, so a typo is a
  visible failure instead of a silently missing affordance.
  """
  def fetch!(name) when is_binary(name) do
    case Map.fetch(@icons, name) do
      {:ok, icon} ->
        icon

      :error ->
        raise ArgumentError, """
        unknown icon #{inspect(name)}

        #{count()} glyphs are vendored in priv/icons. #{suggestion(name)}

        See OpenAgentsWeb.Icons.names/0 to list them.
        """
    end
  end

  defp suggestion(name) do
    stem = name |> String.split("-") |> List.first()

    case Enum.filter(@names, &String.starts_with?(&1, stem)) do
      [] -> "Run `OpenAgentsWeb.Icons.names/0` to list them."
      near -> "Did you mean: #{near |> Enum.take(8) |> Enum.join(", ")}?"
    end
  end
end
