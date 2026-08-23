defmodule OpenAgents.Release.ImageLayerCacheTest do
  @moduledoc """
  Executable proof for RELEASE-007.

  A container layer's cache key includes every `ARG` and `ENV` value declared
  above it in the same stage. A value that moves with the source — the
  candidate SHA, its commit timestamp, the release version — therefore rebuilds
  every instruction below it, no matter what that instruction actually reads.
  Declaring `OPENAGENTS_BUILD_REVISION` at the top of a stage is enough to
  reinstall the operating system, Node.js, Codex, and OpenCode on every
  candidate.

  These tests read the Dockerfile as an ordered instruction list and prove the
  ordering directly: the pinned toolchain installs sit above every per-candidate
  declaration, the revision still reaches `mix compile` so `OpenAgents.BuildInfo`
  compiles the exact SHA in, and the publishing scripts still refuse an image
  whose embedded revision or label is not that SHA.
  """

  use ExUnit.Case, async: true

  # Values that change for every source revision. Nothing that a second
  # candidate would otherwise reuse may sit below one of these.
  @per_candidate ["OPENAGENTS_BUILD_REVISION", "SOURCE_DATE_EPOCH"]

  # Changes on a version bump rather than every commit, but still moves with
  # the source and so belongs below the pinned toolchain.
  @per_version ["OPENAGENTS_RELEASE_VSN"]

  @builder_toolchain [
    {"the Debian snapshot and build dependencies",
     "apt-get install -y --no-install-recommends build-essential"},
    {"the pinned Node.js toolchain", "nodejs.org/dist/v${NODE_VERSION}"},
    {"Hex", "mix local.hex"},
    {"rebar3", "mix local.rebar"}
  ]

  @final_toolchain [
    {"the Debian snapshot and runtime dependencies",
     "apt-get install -y --no-install-recommends libstdc++6"},
    {"the pinned Geist faces", "geist-font/releases/download/v${GEIST_FONT_VERSION}"},
    {"the pinned Codex package", "codex/releases/download/rust-v${CODEX_VERSION}"},
    {"the pinned OpenCode binary", "opencode/releases/download/v${OPENCODE_VERSION}"},
    {"the generated locale", "locale-gen"}
  ]

  describe "toolchain layers key on pinned inputs only" do
    setup do
      %{stages: stages(File.read!("Dockerfile"))}
    end

    test "the builder installs its toolchain above every per-candidate value", %{stages: stages} do
      for variable <- @per_candidate ++ @per_version,
          {label, marker} <- @builder_toolchain do
        assert_declared_after(stages, "builder", variable, label, marker)
      end
    end

    test "the runtime installs its toolchain above every per-candidate value", %{stages: stages} do
      for variable <- @per_candidate,
          {label, marker} <- @final_toolchain do
        assert_declared_after(stages, "final", variable, label, marker)
      end
    end

    test "Mix and npm dependency layers key on the lockfiles, not the revision", %{stages: stages} do
      for variable <- @per_candidate,
          {label, marker} <- [
            {"Mix dependency resolution", "mix deps.get"},
            {"Mix dependency compilation", "mix deps.compile"},
            {"the npm install", "npm ci --prefix assets"},
            {"the Tailwind and esbuild install", "mix assets.setup"}
          ] do
        assert_declared_after(stages, "builder", variable, label, marker)
      end
    end
  end

  describe "the exact candidate identity still reaches the runtime" do
    test "the revision is compiled in above the first application source layer" do
      stages = stages(File.read!("Dockerfile"))

      revision = declaration(stages, "builder", "OPENAGENTS_BUILD_REVISION")
      source = instruction(stages, "builder", "COPY lib lib")
      compile = instruction(stages, "builder", "mix compile --warnings-as-errors")

      assert revision, "the builder stage must declare OPENAGENTS_BUILD_REVISION"
      assert revision < source, "the revision must be set before application source is copied"
      assert revision < compile, "OpenAgents.BuildInfo reads the revision at compile time"

      assert File.read!("lib/openagents/build_info.ex") =~
               "System.get_env(\"OPENAGENTS_BUILD_REVISION\", \"image\")"
    end

    test "the commit timestamp still reaches the runtime image" do
      stages = stages(File.read!("Dockerfile"))

      assert declaration(stages, "builder", "SOURCE_DATE_EPOCH")
      assert declaration(stages, "final", "SOURCE_DATE_EPOCH")

      final = Map.fetch!(stages, "final")

      assert Enum.any?(final, fn {_index, line} ->
               line =~ ~r/^ENV\s+SOURCE_DATE_EPOCH=/
             end),
             "the runtime image must still carry SOURCE_DATE_EPOCH as an ENV"
    end

    test "the release version is declared before the project reads it" do
      stages = stages(File.read!("Dockerfile"))

      version = declaration(stages, "builder", "OPENAGENTS_RELEASE_VSN")
      deps = instruction(stages, "builder", "mix deps.get")

      assert version
      assert version < deps
      assert instruction(stages, "builder", "test -n \"${OPENAGENTS_RELEASE_VSN}\"")
      assert File.read!("mix.exs") =~ "System.get_env(\"OPENAGENTS_RELEASE_VSN\""
    end

    test "publication refuses an image whose revision is not the exact SHA" do
      for script <- ["ops/deploy/build-image.sh", "ops/staging/publish-candidate.sh"] do
        source = File.read!(script)

        assert source =~ "--build-arg \"OPENAGENTS_BUILD_REVISION=$git_sha\""
        assert source =~ "--label \"org.opencontainers.image.revision=$git_sha\""
        assert source =~ "Elixir.OpenAgents.BuildInfo"
      end

      assert File.read!("ops/deploy/build-image.sh") =~
               "packaged BuildInfo revision does not match the exact Git SHA"

      assert File.read!("ops/staging/publish-candidate.sh") =~
               "registry image revision labels do not match the exact Git SHA"
    end
  end

  defp assert_declared_after(stages, stage, variable, label, marker) do
    declaration = declaration(stages, stage, variable)
    install = instruction(stages, stage, marker)

    assert install, "#{stage}: expected an instruction installing #{label}"

    if declaration do
      assert install < declaration,
             "#{stage}: #{label} is installed below #{variable}, so every source revision rebuilds it"
    end
  end

  # First instruction index in `stage` that declares `variable` through ARG or ENV.
  defp declaration(stages, stage, variable) do
    pattern = ~r/^(?:ARG|ENV)\s+#{Regex.escape(variable)}(?:=|\s|$)/

    stages
    |> Map.fetch!(stage)
    |> Enum.find_value(fn {index, line} -> if line =~ pattern, do: index end)
  end

  # First instruction index in `stage` containing `marker`.
  defp instruction(stages, stage, marker) do
    stages
    |> Map.fetch!(stage)
    |> Enum.find_value(fn {index, line} ->
      if String.contains?(line, marker), do: index
    end)
  end

  # The Dockerfile as `%{stage_name => [{index, instruction}]}`, with comments
  # dropped and continuation lines joined the way the builder reads them.
  defp stages(dockerfile) do
    dockerfile
    |> logical_lines()
    |> Enum.with_index()
    |> Enum.reduce({%{}, nil}, fn {line, index}, {acc, stage} ->
      case Regex.run(~r/^FROM\s+\S+\s+AS\s+(\S+)/i, line) do
        [_, name] -> {Map.put_new(acc, name, []), name}
        nil when is_binary(stage) -> {Map.update!(acc, stage, &[{index, line} | &1]), stage}
        nil -> {acc, stage}
      end
    end)
    |> elem(0)
    |> Map.new(fn {stage, lines} -> {stage, Enum.reverse(lines)} end)
  end

  defp logical_lines(dockerfile) do
    dockerfile
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce({[], []}, fn line, {done, pending} ->
      if String.ends_with?(line, "\\") do
        {done, [String.trim_trailing(line, "\\") | pending]}
      else
        {[[line | pending] |> Enum.reverse() |> Enum.join(" ") | done], []}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
