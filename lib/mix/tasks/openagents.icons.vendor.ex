defmodule Mix.Tasks.Openagents.Icons.Vendor do
  @shortdoc "Convert the Apps SDK UI React icon set into vendored SVG files"

  @moduledoc """
  Vendors the `openai/apps-sdk-ui` icon set into `priv/icons`.

      mix openagents.icons.vendor ~/work/projects/repos/apps-sdk-ui

  The converter accepts only the JSX forms in the pinned upstream set. It
  fails when upstream introduces an unsupported expression instead of writing
  a malformed glyph.
  """

  use Mix.Task

  @icon_subpath "src/components/Icon/svg"
  @output "priv/icons"
  @attribute_names %{
    "fillRule" => "fill-rule",
    "clipRule" => "clip-rule",
    "clipPath" => "clip-path",
    "strokeWidth" => "stroke-width",
    "strokeLinecap" => "stroke-linecap",
    "strokeLinejoin" => "stroke-linejoin",
    "strokeMiterlimit" => "stroke-miterlimit",
    "fillOpacity" => "fill-opacity",
    "strokeOpacity" => "stroke-opacity",
    "stopColor" => "stop-color",
    "stopOpacity" => "stop-opacity",
    "className" => "class",
    "xmlnsXlink" => "xmlns:xlink",
    "xlinkHref" => "xlink:href"
  }

  @impl Mix.Task
  def run(arguments) do
    source = arguments |> List.first() |> source_directory!()
    File.mkdir_p!(@output)
    clear_previous_icons()

    written =
      source
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".tsx"))
      |> Enum.sort()
      |> Enum.map(&convert(source, &1))

    Mix.shell().info("Vendored #{length(written)} icons into #{@output}/")

    case Enum.filter(written, &(&1.ids != [])) do
      [] ->
        :ok

      namespaced ->
        Mix.shell().info(
          "Namespaced element IDs in #{length(namespaced)} icons: " <>
            Enum.map_join(namespaced, ", ", & &1.name)
        )
    end
  end

  defp source_directory!(nil) do
    Mix.raise("usage: mix openagents.icons.vendor PATH_TO_APPS_SDK_UI")
  end

  defp source_directory!(path) do
    directory = path |> Path.expand() |> Path.join(@icon_subpath)

    if File.dir?(directory) do
      directory
    else
      Mix.raise("#{directory} does not contain the Apps SDK UI icon source")
    end
  end

  defp clear_previous_icons do
    @output |> Path.join("*.svg") |> Path.wildcard() |> Enum.each(&File.rm!/1)
  end

  defp convert(source, file) do
    component = Path.basename(file, ".tsx")
    name = kebab_case(component)

    svg =
      source
      |> Path.join(file)
      |> File.read!()
      |> extract_svg!(component)
      |> drop_props_spread()
      |> rewrite_attribute_names()
      |> rewrite_expression_values!(component)
      |> namespace_ids(name)
      |> normalize_whitespace()

    File.write!(Path.join(@output, "#{name}.svg"), svg <> "\n")
    %{name: name, ids: Regex.scan(~r/\sid="([^"]+)"/, svg)}
  end

  defp extract_svg!(contents, component) do
    case Regex.run(~r|(<svg\b.*</svg>)|s, contents) do
      [_, svg] -> svg
      _missing -> Mix.raise("#{component}: could not find an <svg> element")
    end
  end

  defp drop_props_spread(svg), do: String.replace(svg, ~r/\s*\{\.\.\.props\}/, "")

  defp rewrite_attribute_names(svg) do
    Enum.reduce(@attribute_names, svg, fn {jsx_name, svg_name}, current ->
      String.replace(current, ~r/(\s)#{jsx_name}=/, "\\1#{svg_name}=")
    end)
  end

  defp rewrite_expression_values!(svg, component) do
    Regex.replace(~r/=\{([^}]*)\}/, svg, fn _match, value ->
      value = String.trim(value)

      if Regex.match?(~r/^-?\d+(\.\d+)?$/, value) do
        ~s(="#{value}")
      else
        Mix.raise("#{component}: unsupported JSX expression value #{inspect(value)}")
      end
    end)
  end

  defp namespace_ids(svg, name) do
    svg
    |> then(&Regex.replace(~r/\sid="([^"]+)"/, &1, ~s( id="#{name}-\\1")))
    |> then(&Regex.replace(~r/url\(#([^)]+)\)/, &1, "url(##{name}-\\1)"))
  end

  defp normalize_whitespace(svg) do
    svg
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.replace(" >", ">")
    |> String.replace("/ >", "/>")
    |> String.trim()
  end

  defp kebab_case(component) do
    component
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1-\\2")
    |> String.replace(~r/([A-Z])([A-Z][a-z])/, "\\1-\\2")
    |> String.downcase()
  end
end
