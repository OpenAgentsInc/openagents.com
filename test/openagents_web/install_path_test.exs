defmodule OpenAgentsWeb.InstallPathTest do
  @moduledoc """
  One way to install, said the same way everywhere a reader is told to.

  `@openagentsinc/cli` is a different program answering to the same name as the
  binary this site serves, and having both on one `PATH` broke `git push`
  machine-wide. The install command moved to `install.sh`, but nine
  documentation pages and two application surfaces went on handing out the npm
  package for long enough that the homepage ended up contradicting the
  documentation it links to (issue #260).

  These assertions read what a reader is actually shown, not what the source
  says about it: the Markdown that becomes a documentation page, and the HTML
  the two install-bearing LiveViews render. A module comment may name the npm
  package -- explaining why it is gone is not offering it -- and this test must
  not turn that into a failure.
  """

  use OpenAgentsWeb.ConnCase, async: true

  @command "curl -fsSL https://openagents.com/install.sh | sh"

  # `npm` alone is too broad: several moduledocs use "pnpm, not npm" as the
  # worked example of a memory whose words do not appear in the request it has
  # to reach. These are the forms that install something.
  @offers_npm ~r{npm i -g|npm install|npx |@openagentsinc/cli}

  test "no documentation page offers npm as a way to install" do
    offenders =
      for path <- Path.wildcard("priv/docs/**/*.md"),
          matches = Regex.scan(@offers_npm, File.read!(path)),
          matches != [],
          do: {Path.relative_to_cwd(path), matches |> List.flatten() |> Enum.uniq()}

    assert offenders == [],
           """
           These documentation pages still offer the npm package:

           #{Enum.map_join(offenders, "\n", fn {path, found} -> "  #{path}: #{Enum.join(found, ", ")}" end)}

           The one install path is `#{@command}`. See /docs/install-cli.
           """
  end

  test "at least one documentation page prints the installer, so this test can fail" do
    # Without this, deleting every mention of installing anything would pass the
    # assertion above while leaving a reader with no way in.
    printed? =
      Enum.any?(Path.wildcard("priv/docs/**/*.md"), &String.contains?(File.read!(&1), @command))

    assert printed?, "no documentation page prints #{@command}"
  end

  test "the coder page prints the installer and not the npm package", %{conn: conn} do
    html = conn |> get(~p"/coder") |> html_response(200)

    assert html =~ @command
    refute html =~ @offers_npm
  end

  test "the repository list prints the installer and not the npm package", %{conn: conn} do
    html =
      conn
      |> log_in_github_user("install-path-repository-list")
      |> get(~p"/repositories")
      |> html_response(200)

    assert html =~ @command
    refute html =~ @offers_npm
  end
end
