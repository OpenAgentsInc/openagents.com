defmodule OpenAgents.MixProject do
  use Mix.Project

  def project do
    [
      app: :openagents,
      version: release_version(),
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      test_coverage: [
        summary: [threshold: 83.0],
        local_only: false,
        # Release gates cover operational entry points. Keep this threshold
        # focused on application runtime code, not generated and test-only modules.
        ignore_modules: [
          ~r/^Inspect\./,
          ~r/^Mix\.Tasks\./,
          ~r/^OpenAgents\.Test\./,
          OpenAgents.Release,
          OpenAgents.ReleaseAssembler,
          OpenAgentsWeb.ChannelCase
        ]
      ],
      deps: deps(),
      compilers: [:appup, :phoenix_live_view] ++ Mix.compilers(),
      appup: "rel/openagents.appup.exs",
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {OpenAgents.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp release_version do
    System.get_env("OPENAGENTS_RELEASE_VSN", "0.2.0")
  end

  # Hot-upgrade-capable release: castle/forecastle add appup + relup generation
  # and release_handler runtime support on top of `mix release`.
  defp releases do
    release_path = System.get_env("OPENAGENTS_RELEASE_PATH")

    options =
      [
        include_erts: true,
        include_src: false,
        cookie: "openagents-nondistributed-placeholder",
        steps: [
          &OpenAgents.ReleaseAssembler.pre_assemble/1,
          :assemble,
          &OpenAgents.ReleaseAssembler.post_assemble/1,
          :tar
        ]
      ]

    options = if release_path, do: Keyword.put(options, :path, release_path), else: options

    [
      openagents: options
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       ref: "0435d4ca364a608cc75e2f8683d374e55abbae26",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:mdex, "~> 0.13.5"},
      {:horde, "~> 0.9.0"},
      {:ra, "~> 2.16"},
      {:websockex, "~> 0.5.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:posthog, "~> 2.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:castle, "~> 0.3.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind openagents", "esbuild openagents"],
      "assets.test": ["cmd --cd assets npm test"],
      "assets.deploy": [
        "compile",
        "tailwind openagents --minify",
        "esbuild openagents --minify",
        "phx.digest"
      ],
      precommit: [
        "hex.audit",
        "deps.audit",
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format",
        "cmd ops/ci/reference-check.sh",
        "cmd elixir ops/ci/docs-check.exs",
        "assets.test",
        "test --warnings-as-errors"
      ]
    ]
  end
end
