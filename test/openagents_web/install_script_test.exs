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

  test "the installer is served under the name the published command uses" do
    assert "install.sh" in OpenAgentsWeb.static_paths(),
           "`install.sh` is not in static_paths/0, so /install.sh is a 404"

    assert Enum.any?(OpenAgentsWeb.static_prefixes(), &String.starts_with?("install.sh", &1)),
           "no prefix in static_prefixes/0 covers install.sh, so it 404s once digested"
  end

  test "the script parses" do
    assert {_output, 0} = System.cmd("bash", ["-n", @script], stderr_to_stdout: true)
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

  test "the channel resolves a version rather than hardcoding one" do
    script = File.read!(@script)

    refute script =~ ~r/^\s*version="0\.1\.0"/m,
           "the installer still hardcodes a version, so the channel decides nothing"

    assert script =~ "${BASE_URL_PRIMARY}/${CHANNEL}",
           "the installer never reads the channel pointer"
  end
end
