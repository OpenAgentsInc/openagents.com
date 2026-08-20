defmodule OpenAgentsWeb.StaticFilesTest do
  @moduledoc """
  Static files must still be served once they are digested.

  `Plug.Static`'s `:only` matches a whole path segment, and digesting rewrites
  the segment -- `favicon-32x32.png` is requested as
  `favicon-32x32-<hash>.png`. Listing the plain name therefore admits the file
  in development, where nothing is digested, and refuses it in every
  environment that runs `mix phx.digest`. Staging served `/favicon-32x32.png`
  with a 200 and the digested name the page actually asked for with a 404, so
  the icon was missing in exactly the places it is seen most.

  These run the real `Plug.Static` with the real options over a temporary
  directory, rather than re-implementing its matching rules, because the bug
  was a misunderstanding of those rules -- a copy of them would have had the
  same misunderstanding and passed.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  @digest "0123456789abcdef0123456789abcdef"

  setup do
    root = Path.join(System.tmp_dir!(), "static-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "every root file is served under its digested name", %{root: root} do
    for path <- root_files() do
      digested = digested_name(path)

      write!(root, digested, "body of #{path}")

      assert %{status: 200} = request(root, "/" <> digested),
             """
             `#{path}` is listed in `static_paths/0` but its digested name
             `#{digested}` is refused, so it 404s wherever assets are digested.
             Add a covering prefix to `OpenAgentsWeb.static_prefixes/0`.
             """
    end
  end

  test "every root file is still served under its plain name", %{root: root} do
    for path <- root_files() do
      write!(root, path, "body of #{path}")
      assert %{status: 200} = request(root, "/" <> path), "#{path} is no longer served"
    end
  end

  test "directories of assets are served digested, as the segment is the directory",
       %{root: root} do
    for directory <- root_directories() do
      write!(root, Path.join(directory, "app-#{@digest}.js"), "console.log(1)")

      assert %{status: 200} = request(root, "/#{directory}/app-#{@digest}.js")
    end
  end

  test "widening the match does not serve a file that is not listed", %{root: root} do
    # `only_matching` admits names by prefix, so it is worth stating that it
    # has not turned the static root into an open directory.
    write!(root, "secrets.txt", "nope")
    write!(root, "favicons-are-fine.txt", "also nope")

    assert %{status: 404} = request(root, "/secrets.txt")
    assert %{status: 200} = request(root, "/favicons-are-fine.txt")
  end

  test "a prefix that matches nothing listed is dead weight" do
    # Not a correctness failure, but a prefix nobody needs widens what may be
    # served for no reason, and is usually a leftover.
    for prefix <- OpenAgentsWeb.static_prefixes() do
      assert Enum.any?(OpenAgentsWeb.static_paths(), &String.starts_with?(&1, prefix)),
             "`#{prefix}` covers nothing in static_paths/0"
    end
  end

  defp root_files do
    Enum.filter(OpenAgentsWeb.static_paths(), &String.contains?(&1, "."))
  end

  defp root_directories do
    Enum.reject(OpenAgentsWeb.static_paths(), &String.contains?(&1, "."))
  end

  # `mix phx.digest` names a digested file `<base>-<hash><extension>`.
  defp digested_name(path) do
    extension = Path.extname(path)
    Path.basename(path, extension) <> "-" <> @digest <> extension
  end

  defp write!(root, path, contents) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
  end

  defp request(root, path) do
    options = Plug.Static.init(OpenAgentsWeb.static_options(from: root))

    :get
    |> conn(path)
    |> Plug.Static.call(options)
    |> then(fn conn -> if conn.state == :unset, do: send_resp(conn, 404, ""), else: conn end)
  end
end
