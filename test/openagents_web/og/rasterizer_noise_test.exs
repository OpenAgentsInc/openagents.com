defmodule OpenAgentsWeb.OG.RasterizerNoiseTest do
  use ExUnit.Case, async: false

  alias OpenAgentsWeb.OG.Rasterizer

  @png <<0x89, "PNG\r\n", 0x1A, "\n", "rest-of-a-card">>

  setup do
    previous = Application.get_env(:openagents, :og_rasterizer_bin)
    on_exit(fn -> Application.put_env(:openagents, :og_rasterizer_bin, previous) end)
    :ok
  end

  defp fake_binary(script) do
    path = Path.join(System.tmp_dir!(), "fake-rsvg-#{System.unique_integer([:positive])}")
    File.write!(path, script)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    Application.put_env(:openagents, :og_rasterizer_bin, path)
    path
  end

  test "a chatty binary cannot pollute the card" do
    # The production failure: warnings on stderr, a good PNG at -o, exit 0.
    fake_binary("""
    #!/bin/sh
    echo "Fontconfig error: No writable cache directories" >&2
    echo "Fontconfig error: No writable cache directories" >&2
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) shift; out="$1" ;;
      esac
      shift
    done
    printf '\\211PNG\\r\\n\\032\\nrest-of-a-card' > "$out"
    exit 0
    """)

    assert {:ok, png} = Rasterizer.rasterize("<svg/>")
    assert png == @png
    assert binary_part(png, 0, 8) == <<0x89, "PNG\r\n", 0x1A, "\n">>
  end

  test "output that is not a PNG fails closed" do
    fake_binary("""
    #!/bin/sh
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) shift; out="$1" ;;
      esac
      shift
    done
    printf 'Fontconfig error: No writable cache directories' > "$out"
    exit 0
    """)

    assert {:error, :rasterizer_failed} = Rasterizer.rasterize("<svg/>")
  end
end
