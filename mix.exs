defmodule Slackex.MixProject do
  use Mix.Project

  def project do
    [
      app: :slackex,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:mix, :ex_unit],
        flags: [:unmatched_returns, :error_handling, :no_opaque]
      ]
    ]
  end

  def application do
    [
      mod: {Slackex.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core Phoenix
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5"},
      {:dns_cluster, "~> 0.2.0"},
      {:gettext, "~> 0.26"},

      # Auth
      {:bcrypt_elixir, "~> 3.0"},
      {:guardian, "~> 2.3"},

      # Content safety
      {:html_sanitize_ex, "~> 1.4"},

      # Background jobs
      {:oban, "~> 2.18"},

      # Distribution & clustering
      {:horde, "~> 0.9"},
      {:libcluster, "~> 3.4"},

      # Telemetry
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},

      # Assets
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},

      # Dev & Test
      {:tidewave, "~> 0.5", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_machina, "~> 2.8", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build", "git_hooks.install"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind slackex", "esbuild slackex"],
      "assets.deploy": [
        "tailwind slackex --minify",
        "esbuild slackex --minify",
        "phx.digest"
      ],
      lint: ["format --check-formatted", "credo --strict", "compile --warnings-as-errors"],
      "lint.fix": ["format"],
      typecheck: ["dialyzer"],
      quality: ["lint", "typecheck", "test"],
      ci: [
        "deps.get",
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "test"
      ]
    ]
  end
end
