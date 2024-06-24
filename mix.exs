defmodule PhoenixAssetPipeline.MixProject do
  use Mix.Project

  @description "Asset pipeline for Phoenix app"
  @runtimes Mix.env() in [:dev, :test]
  @source_url "https://github.com/Youimmi/phoenix_asset_pipeline"
  @version "0.1.3"

  def project do
    [
      app: :phoenix_asset_pipeline,
      version: @version,
      compilers: Mix.compilers(),
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      description: @description,
      package: package(),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:iex, :mix, :phoenix_live_view]],
      source_url: @source_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {PhoenixAssetPipeline.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      files: ["lib", "LICENSE", "mix.exs", "README.md"],
      maintainers: ["Yuri S."],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.5.5", override: true},
      {:brotli, "~> 0.3"},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dart_sass, "~> 0.6", runtime: @runtimes},
      {:dialyxir, "~> 1.3", only: :dev, runtime: false},
      {:esbuild, "~> 0.7", runtime: @runtimes},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false},
      {:floki, "~> 0.34"},
      {:jason, "~> 1.5.0-alpha.1"},
      {:jason_native, "~> 0.1.0"},
      {:mix_audit, "~> 2.1", only: :dev, runtime: false},
      {:phoenix, "~> 1.7.2", runtime: false},
      {:phoenix_html, "~> 3.3"},
      {:phoenix_live_view, "~> 0.18", runtime: @runtimes}
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
      pre_commit: [
        "compile --force --warnings-as-errors",
        "credo -A",
        "deps.audit",
        "dialyzer",
        "format --check-formatted --dry-run",
        "hex.audit",
        "hex.outdated"
      ],
      setup: ["cmd rm -rf _build deps", "deps.get"],
      upgrade: ["cmd rm -rf mix.lock", "setup"]
    ]
  end
end
