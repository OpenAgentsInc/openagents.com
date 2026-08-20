defmodule Mix.Tasks.Openagents.Relup do
  @moduledoc """
  Generates a two-way `relup` in an explicit output directory.

      mix openagents.relup --target /path/to/0.2.0/openagents \
        --from /path/to/0.1.0/openagents --outdir /tmp/proof
  """

  use Mix.Task

  @shortdoc "Generates an explicit two-way OpenAgents relup"
  @switches [target: :string, from: :string, outdir: :string]

  @impl true
  def run(arguments) do
    {options, remaining, invalid} = OptionParser.parse(arguments, strict: @switches)

    if remaining != [] or invalid != [] do
      Mix.raise("openagents.relup received unsupported arguments")
    end

    target = required_path!(options, :target)
    from = required_path!(options, :from)
    outdir = required_directory!(options, :outdir)

    paths =
      [target, from]
      |> Enum.flat_map(fn release ->
        release
        |> Path.join("../../../lib/*/ebin")
        |> Path.expand()
        |> Path.wildcard()
      end)
      |> Enum.uniq()
      |> Enum.map(&to_charlist/1)

    case :systools.make_relup(
           to_charlist(target),
           [to_charlist(from)],
           [to_charlist(from)],
           path: paths,
           outdir: to_charlist(outdir),
           silent: true,
           warnings_as_errors: true
         ) do
      {:ok, _relup, _module, []} ->
        Mix.shell().info("Generated #{Path.join(outdir, "relup")}")

      {:ok, _relup, module, warnings} ->
        Mix.raise(
          "relup generation produced warnings: #{format(module, :format_warning, warnings)}"
        )

      {:error, module, reason} ->
        Mix.raise("relup generation failed: #{format(module, :format_error, reason)}")

      other ->
        Mix.raise("relup generation returned #{inspect(other)}")
    end
  end

  defp required_path!(options, key) do
    path = options |> Keyword.fetch!(key) |> Path.expand()

    if File.regular?(path <> ".rel"),
      do: path,
      else: Mix.raise("--#{key} must name a release resource without the .rel suffix")
  end

  defp required_directory!(options, key) do
    path = options |> Keyword.fetch!(key) |> Path.expand()
    File.mkdir_p!(path)
    path
  end

  defp format(module, function, value) do
    module
    |> apply(function, [value])
    |> IO.iodata_to_binary()
  end
end
