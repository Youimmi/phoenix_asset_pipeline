defmodule PhoenixAssetPipeline.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description """
  Asset pipeline for Phoenix app
  """

  def project do
    [
      app: :phoenix_asset_pipeline,
      version: @version,
      compilers: Mix.compilers(),
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      description: @description,
      package: package(),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      source_url: "https://github.com/Youimmi/phoenix_asset_pipeline"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: mod(iex_running?()),
      extra_applications: [:logger]
    ]
  end

  defp mod(false), do: {PhoenixAssetPipeline, []}
  defp mod(_), do: []

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end

  defp package do
    [
      files: ["lib", "LICENSE", "mix.exs", "README.md"],
      maintainers: [],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/Youimmi/phoenix_asset_pipeline"}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:brotli, "~> 0.3.0"},
      {:credo, github: "rrrene/credo", only: [:dev, :test], runtime: false},
      {:dart_sass, github: "CargoSense/dart_sass", runtime: Mix.env() == :dev},
      {:dialyxir, "~> 1.1", only: [:dev, :test], runtime: false},
      {:esbuild, github: "phoenixframework/esbuild", runtime: Mix.env() == :dev, override: true},
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      {:floki, ">= 0.32.0"},
      {:jason, "~> 1.3"},
      {:phoenix, "~> 1.6"},
      {:phoenix_html, "~> 3.2"},
      {:phoenix_live_view, "~> 0.17", optional: true},
      {:plug_cowboy, "~> 2.5"}
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
      setup: ["deps.get"],
      upgrade: ["cmd rm -rf _build deps mix.lock", "setup"]
    ]
  end
end
