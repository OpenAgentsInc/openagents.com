defmodule OpenAgentsWeb.OG.Rasterizer do
  @moduledoc """
  SVG to PNG, the one impure step in the card pipeline.

  The production path shells out to `rsvg-convert` (librsvg) with a fixed
  width/height and no user-influenced flags: the SVG itself is the only input,
  and every dynamic string inside it was escaped and clamped by
  `OpenAgentsWeb.OG` long before it got here. Fonts come from the release
  image's fontconfig; when the binary is absent the module reports
  `:unavailable` and callers serve the committed fallback card instead of
  erroring.

  Work is bounded twice: a concurrency limiter (`OpenAgentsWeb.OG.Limiter`)
  caps simultaneous ports, and each run has a hard timeout. Tests can replace
  the whole behavior with `:og_rasterizer_mfa`, an MFA applied to the SVG.
  """

  require Logger

  @timeout_ms 5_000

  # The eight bytes every PNG starts with. The card is checked against them
  # before it is served, because the failure this guards against answers 200.
  @png_signature <<0x89, "PNG\r\n", 0x1A, "\n">>

  @type error :: :unavailable | :busy | :rasterizer_failed | :timeout | {:exit, term()}

  @doc """
  Renders one card's SVG to PNG bytes.

  Test seam: set `Application.put_env(:openagents, :og_rasterizer_mfa,
  {Mod, :fun, []})` and it receives the SVG instead of the port pipeline.
  """
  @spec rasterize(String.t(), keyword()) :: {:ok, binary()} | {:error, error()}
  def rasterize(svg, opts \\ []) do
    case Application.get_env(:openagents, :og_rasterizer_mfa) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        apply(mod, fun, [svg | args])

      _mfa_absent ->
        port_rasterize(svg, opts)
    end
  end

  @doc "Whether the configured rasterizer binary exists on this node."
  def available? do
    case System.find_executable(binary_name()) do
      nil -> false
      _path -> true
    end
  end

  defp port_rasterize(svg, opts) do
    bin = binary_name()

    unless executable?(bin) do
      {:error, :unavailable}
    else
      case OpenAgentsWeb.OG.Limiter.acquire() do
        :ok ->
          try do
            run(bin, svg, opts)
          after
            OpenAgentsWeb.OG.Limiter.release()
          end

        :busy ->
          {:error, :busy}
      end
    end
  end

  # find_executable walks PATH per call; cache the verdict per binary name so
  # a burst of cold card requests does not turn into a burst of scans.
  defp executable?(bin) do
    key = {__MODULE__, :executable, bin}

    case :persistent_term.get(key, nil) do
      nil ->
        found = System.find_executable(bin) != nil
        :persistent_term.put(key, found)
        found

      verdict ->
        verdict
    end
  end

  defp run(bin, svg, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)
    source = temp_path("svg")
    target = temp_path("png")

    try do
      File.write!(source, svg)

      task =
        Task.async(fn ->
          System.cmd(bin, port_args(source, target),
            stderr_to_stdout: true,
            env: environment()
          )
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {diagnostics, 0}} ->
          read_card(target, diagnostics)

        {:ok, {_output, status}} ->
          Logger.warning("og_rasterizer_failed exit=#{status}")
          {:error, :rasterizer_failed}

        nil ->
          Logger.warning("og_rasterizer_timeout")
          {:error, :timeout}

        {:exit, reason} ->
          {:error, {:exit, reason}}
      end
    rescue
      error in File.Error -> {:error, {:file, error.reason}}
    after
      File.rm(source)
      File.rm(target)
    end
  end

  # The image comes off disk, never off the pipe. librsvg writes the PNG to
  # `-o` and its warnings to stderr, and this call merges stderr into stdout
  # deliberately -- so that a warning is logged rather than lost -- which is
  # exactly why the bytes cannot come from there. They did once: a container
  # whose fontconfig had no writable cache emitted "No writable cache
  # directories" five times per render, the collector returned those 240 bytes
  # with the PNG behind them, the signature was no longer at byte zero, and
  # every card on the site failed to decode while the endpoint answered 200.
  defp read_card(target, diagnostics) do
    log_diagnostics(diagnostics)

    case File.read(target) do
      {:ok, <<@png_signature::binary, _rest::binary>> = png} ->
        {:ok, png}

      {:ok, _other} ->
        # Exit zero and bytes that are not a PNG: the binary is telling the
        # truth about its exit and lying about its output. Fail to the
        # committed card rather than serve something no decoder accepts.
        Logger.warning("og_rasterizer_not_png")
        {:error, :rasterizer_failed}

      {:error, reason} ->
        Logger.warning("og_rasterizer_unreadable code=#{reason}")
        {:error, :rasterizer_failed}
    end
  end

  defp log_diagnostics(""), do: :ok

  defp log_diagnostics(diagnostics) do
    # One bounded line. The binary's chatter is operational evidence, not card
    # content, and it must never reach a response body again.
    Logger.warning("og_rasterizer_diagnostics=#{inspect(String.slice(diagnostics, 0, 200))}")
  end

  # fontconfig wants a writable cache directory and `nobody` has no home, so
  # without this every render pays for a miss and says so on stderr.
  defp environment, do: [{"XDG_CACHE_HOME", System.tmp_dir!()}]

  defp port_args(source, target),
    do: ["-f", "png", "-w", "1200", "-h", "630", "--keep-aspect-ratio", "-o", target, source]

  defp temp_path(extension),
    do:
      Path.join(
        System.tmp_dir!(),
        "og-" <> Integer.to_string(System.unique_integer([:positive])) <> "." <> extension
      )

  defp binary_name, do: Application.get_env(:openagents, :og_rasterizer_bin, "rsvg-convert")
end
