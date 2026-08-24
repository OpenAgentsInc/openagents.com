defmodule OpenAgents.HostedCIAbsenceTest do
  @moduledoc """
  The executable enumeration behind RELEASE-004's absence clause.

  RELEASE-004 says the release gate permits no hosted CI: no GitHub Actions
  workflows, no GitHub-hosted or third-party runners, and no repository
  automation handed to external CI compute. Its proofs, `ops/ci/gate.sh` and
  `OpenAgents.Forge.GateReceiptTest`, establish that the owned gate runs and
  binds its receipt to a candidate SHA. Neither reads the repository for a
  hosted-CI configuration, so committing `.github/workflows/ci.yml` would leave
  both green while the sentence became false.

  Absence is a claim about a population, so it is checked by reading the
  population. The configuration directories below are where every hosted
  provider looks; a file appearing under one of them fails here until
  RELEASE-004 is amended to say what runs there and why it is owned.
  """

  use ExUnit.Case, async: true

  @hosted_ci_paths [
    ".github/workflows",
    ".circleci",
    ".gitlab-ci.yml",
    ".travis.yml",
    "azure-pipelines.yml",
    "appveyor.yml",
    ".buildkite",
    ".drone.yml",
    "Jenkinsfile"
  ]

  test "the repository configures no hosted CI provider" do
    present = Enum.filter(@hosted_ci_paths, &File.exists?(root(&1)))

    assert present == [], """
    The repository carries hosted CI configuration:

    #{Enum.map_join(present, "\n", &"  #{&1}")}

    RELEASE-004 says all checks run on owned machines and the target release
    gate permits no hosted CI. Remove the configuration, or amend RELEASE-004
    to state what an external runner does and what evidence it may produce.
    """
  end

  test "no workflow file hides under another .github path" do
    workflows =
      root(".github")
      |> Path.join("**/*.{yml,yaml}")
      |> Path.wildcard()

    assert workflows == [], """
    A workflow definition lives under `.github/`:

    #{Enum.map_join(workflows, "\n", &"  #{Path.relative_to(&1, root("."))}")}

    RELEASE-004 admits no GitHub-hosted or third-party runner.
    """
  end

  defp root(path), do: Path.join(File.cwd!(), path)
end
