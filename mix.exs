defmodule Nspark.MixProject do
  use Mix.Project

  def project do
    [
      app: :nspark,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      usage_rules: usage_rules()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Nspark.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp usage_rules do
    # Example for those using claude.
    [
      file: "CLAUDE.md",
      # rules to include directly in CLAUDE.md
      # use a regex to match multiple deps, or atoms/strings for specific ones
      usage_rules: [:usage_rules, :ash, ~r/^ash_/],
      # If your CLAUDE.md is getting too big, link instead of inlining:
      usage_rules: [:usage_rules, :ash, {~r/^ash_/, link: :markdown}],
      # or use skills
      skills: [
        location: ".claude/skills",
        # Pull in pre-built skills shipped directly by packages
        package_skills: [:ash, ~r/^ash_/],
        # build skills that combine multiple usage rules
        build: [
          "ash-framework": [
            # The description tells people how to use this skill.
            description:
              "Use this skill working with Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes.",
            # Include all Ash dependencies
            usage_rules: [:ash, ~r/^ash_/]
          ],
          "phoenix-framework": [
            description:
              "Use this skill working with Phoenix Framework. Consult this when working with the web layer, controllers, views, liveviews etc.",
            # Include all Phoenix dependencies
            usage_rules: [:phoenix, ~r/^phoenix_/]
          ]
        ]
      ]
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
      {:live_svelte, "~> 0.18"},
      {:bcrypt_elixir, "~> 3.0"},
      {:picosat_elixir, "~> 0.2"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:oban, "~> 2.0"},
      {:open_api_spex, "~> 3.0"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:ash_cloak, "~> 0.3"},
      {:cloak, "~> 1.0"},
      {:ash_ai, "~> 0.7"},
      {:ash_paper_trail, "~> 0.6"},
      {:tidewave, "~> 0.6", only: [:dev]},
      {:live_debugger, "~> 1.0", only: [:dev]},
      {:ash_state_machine, "~> 0.2"},
      {:oban_web, "~> 2.0"},
      {:ash_oban, "~> 0.8"},
      {:ash_admin, "~> 1.0"},
      {:ash_authentication_phoenix, "~> 2.0"},
      {:ash_authentication, "~> 4.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash_json_api, "~> 1.0"},
      {:ash_phoenix, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:live_agent,
       if(Mix.env() == :dev and File.dir?("/Volumes/x/projects/elixir_libs/live_agent"),
         do: [path: "/Volumes/x/projects/elixir_libs/live_agent", override: true, only: :dev],
         else: [github: "sunprema/live_agent", branch: "main", only: :dev]
       )},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
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
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["phoenix_vite.npm assets install"],
      "assets.build": [
        "phoenix_vite.npm vite build --manifest --emptyOutDir true",
        "phoenix_vite.npm vite build --ssrManifest --emptyOutDir false --ssr js/server.js --outDir ../priv/svelte"
      ],
      "assets.deploy": [
        "assets.build"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
