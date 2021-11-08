defmodule AssetPipeline.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description """
  Asset pipeline for Phoenix app
  """

  def project do
    [
      app: :asset_pipeline,
      version: @version,
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      description: @description,
      package: package(),
      deps: deps(),
      aliases: aliases(),
      source_url: "https://github.com/Youimmi/asset_pipeline"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {AssetPipeline, []},
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      files: ["lib", "LICENSE", "mix.exs", "README.md"],
      maintainers: [],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/Youimmi/asset_pipeline"}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.6.0-rc.1", only: [:dev, :test], runtime: false},
      {:dart_sass, github: "CargoSense/dart_sass", runtime: Mix.env() == :dev},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},
      {:esbuild, github: "phoenixframework/esbuild", runtime: Mix.env() == :dev},
      {:ex_doc, "~> 0.25", only: :dev, runtime: false},
      {:jason, "~> 1.2"},
      {:phoenix, "~> 1.6.2"},
      {:phoenix_html, "~> 3.1"},
      {:phoenix_live_view, "~> 0.17", optional: true},
      {:plug_cowboy, "~> 2.5"},
      {:rambo, "~> 0.3"}
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
      upgrade: ["cmd rm -rf _build deps mix.lock", "deps.get"]
    ]
  end
end
