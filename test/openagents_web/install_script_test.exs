defmodule OpenAgentsWeb.InstallScriptTest do
  @moduledoc """
  The installer is a published entry point, so what it refuses matters.

  `curl -fsSL https://openagents.com/install.sh | bash` hands a shell script
  the right to write an executable onto the reader's machine and put it on
  their PATH. Two properties keep that honest: the script has to actually be
  served under that name, and it has to refuse anything it cannot verify.

  The refusals are asserted against the script's own text rather than by
  running it, because running it means reaching the network. `bash -n` proves
  it parses; the behaviour these assert -- no unverified install, no
  unnamed source -- is proven end to end against a fixture release server in
  the issue's record.
  """

  use ExUnit.Case, async: true

  @script Path.join([File.cwd!(), "priv", "static", "install.sh"])

  defp libc(source, arch, root) do
    {output, 0} =
      System.cmd("bash", ["-c", ". #{source}; linux_libc #{arch} #{root}"],
        stderr_to_stdout: true
      )

    String.trim(output)
  end

  defp fixture(dir, name, paths) do
    root = Path.join(dir, name)
    File.mkdir_p!(root)

    Enum.each(paths, fn path ->
      absolute = Path.join(root, path)
      File.mkdir_p!(Path.dirname(absolute))
      File.write!(absolute, "")
    end)

    root
  end

  test "the installer is served under the name the published command uses" do
    assert "install.sh" in OpenAgentsWeb.static_paths(),
           "`install.sh` is not in static_paths/0, so /install.sh is a 404"

    assert Enum.any?(OpenAgentsWeb.static_prefixes(), &String.starts_with?("install.sh", &1)),
           "no prefix in static_prefixes/0 covers install.sh, so it 404s once digested"
  end

  test "the script parses" do
    assert {_output, 0} = System.cmd("bash", ["-n", @script], stderr_to_stdout: true)
  end

  test "the script needs no shell Alpine does not ship" do
    # The musl builds exist for Alpine above all, and Alpine ships no bash.
    # `curl … | bash` there fails before the first line runs, with an error
    # about the shell rather than about anything the reader did. So this is
    # POSIX shell, and these are the three things that would quietly make it
    # bash again.
    assert {_output, 0} = System.cmd("sh", ["-n", @script], stderr_to_stdout: true)

    script = File.read!(@script)

    body =
      script
      |> String.replace(~r/^#.*$/m, "")
      # `[[:space:]]` and its siblings are POSIX character classes. They are
      # valid in `sh` and in POSIX `grep -E`, busybox included, and they
      # contain `[[` without being a bash conditional. Drop them before
      # looking for one, or the check below fails on correct POSIX code.
      |> String.replace(~r/\[\[:[a-z]+:\]\]/, "")

    refute body =~ "[[", "`[[ ]]` is a bash conditional"
    refute body =~ "=~", "`=~` is a bash regex match"
    refute body =~ ~r/\[@\]/, "an array expansion is bash-only"
  end

  test "nothing is installed without a checksum that matches" do
    script = File.read!(@script)

    assert script =~ "SHA256SUMS-",
           "the installer does not fetch a sums file"

    assert script =~ "refusing to install unverified bytes",
           "the installer does not refuse when the sums file is missing"

    assert script =~ "Checksum mismatch",
           "the installer does not refuse a mismatched artifact"
  end

  test "there is no path that installs a binary nobody named" do
    script = File.read!(@script)

    # The removed fallback copied ./target/release/oa, ./target/debug/oa, or an
    # already-installed binary when the download failed, so running the
    # installer anywhere near a stale build installed that build while
    # reporting the version it meant to fetch.
    refute script =~ ~r/^\s*cp\s+"?\.\/target\//m,
           "the installer copies a local build when the download fails"

    refute script =~ ~r/^\s*cp\s+"\$HOME\/\.openagents\/bin/m,
           "the installer reinstalls whatever is already on disk"
  end

  describe "libc detection" do
    # `linux_libc` is extracted from the served script and run against fixture
    # roots, so these assert the code readers actually receive rather than a
    # copy of it. The choice matters more than most: a glibc binary on a musl
    # system fails at exec with "no such file or directory" naming a file that
    # is plainly there, and nothing in that message points at the installer.
    setup do
      script = File.read!(@script)

      [function] = Regex.run(~r/^linux_libc\(\).*?^\}/ms, script)

      dir = Path.join(System.tmp_dir!(), "install-libc-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      source = Path.join(dir, "linux_libc.sh")
      File.write!(source, function)

      {:ok, source: source, dir: dir}
    end

    test "a present glibc loader means the dynamically linked build runs", context do
      root = fixture(context.dir, "glibc", ["lib64/ld-linux-x86-64.so.2"])

      assert libc(context.source, "x86_64", root) == "gnu"
    end

    test "a multiarch glibc loader counts too", context do
      root = fixture(context.dir, "multiarch", ["lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"])

      assert libc(context.source, "x86_64", root) == "gnu"
    end

    test "no glibc loader means only the static build runs", context do
      root = fixture(context.dir, "alpine", ["lib/ld-musl-x86_64.so.1"])

      assert libc(context.source, "x86_64", root) == "musl"
    end

    test "an image carrying no libc at all still resolves to the static build", context do
      root = fixture(context.dir, "bare", [])

      assert libc(context.source, "x86_64", root) == "musl"
      assert libc(context.source, "aarch64", root) == "musl"
    end

    test "a glibc host with the musl package installed is still glibc", context do
      # Debian's `musl` package drops a musl loader onto a glibc system. The
      # question is which artifact runs, not which loaders exist, and both do.
      root =
        fixture(context.dir, "both", [
          "lib64/ld-linux-x86-64.so.2",
          "lib/ld-musl-x86_64.so.1"
        ])

      assert libc(context.source, "x86_64", root) == "gnu"
    end

    test "each architecture is judged by its own loader", context do
      root = fixture(context.dir, "arm", ["lib/ld-linux-aarch64.so.1"])

      assert libc(context.source, "aarch64", root) == "gnu"

      # The x86_64 loader is absent from this root, and an architecture's
      # verdict must not be borrowed from another's.
      assert libc(context.source, "x86_64", root) == "musl"
    end

    test "an architecture with no musl build asks for the glibc one", context do
      root = fixture(context.dir, "riscv", [])

      assert libc(context.source, "riscv64", root) == "gnu"
    end
  end

  test "the musl platform is named the way the release publishes it" do
    script = File.read!(@script)

    assert script =~ ~s(platform="${platform}-musl"),
           "the installer detects musl and then asks for the same artifact anyway"

    refute script =~ ~s(platform="${os}-${arch}-${libc}"),
           "the glibc artifact is renamed, which breaks every installer already in circulation"
  end

  test "the channel resolves a version rather than hardcoding one" do
    script = File.read!(@script)

    refute script =~ ~r/^\s*version="0\.1\.0"/m,
           "the installer still hardcodes a version, so the channel decides nothing"

    assert script =~ "${BASE_URL_PRIMARY}/${CHANNEL}",
           "the installer never reads the channel pointer"
  end

  describe "the name it installs" do
    # This reverses the `oa`-only rule. That rule existed because the Rust
    # binary answered a strict subset of the CLI's commands, so taking the
    # `openagents` name swapped a fraction of the CLI in underneath every
    # script that called it. That is no longer true: the shipped binary
    # dispatches the whole command set and is the coder session besides.
    test "installs openagents, coder, and oa for the same binary" do
      script = File.read!(@script)

      assert script =~ ~s(ln -sf "$link_target" "$BIN_DIR/openagents"),
             "the installer does not create the openagents name"

      assert script =~ ~s(ln -sf "$link_target" "$BIN_DIR/coder"),
             "the installer does not create the coder name"

      assert script =~ ~s(ln -sf "$link_target" "$BIN_DIR/oa"),
             "the installer does not create the oa alias"
    end

    test "says one line about what it installed, and names openagents" do
      script = File.read!(@script)

      assert script =~ ~s(OpenAgents $version installed. Run 'openagents' to start.)

      # The closing block used to carry a shadow warning, a PATH comparison and
      # a note about a different CLI. It was noise on a successful install.
      refute script =~ "TypeScript CLI",
             "the installer talks about a different CLI"

      refute script =~ "npm i -g",
             "the installer sends the reader somewhere else"

      refute script =~ "installs 'oa' only",
             "the installer still claims it installs oa only"
    end
  end
end
