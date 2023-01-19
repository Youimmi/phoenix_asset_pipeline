defmodule PhoenixAssetPipeline.MixProject do
  use Mix.Project

  @description "Asset pipeline for Phoenix app"
  @runtimes Mix.env() in [:dev, :test]
  @source_url "https://github.com/Youimmi/phoenix_asset_pipeline"
  @version "0.1.1"

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
      mod: {PhoenixAssetPipeline, []},
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
      {:brotli, "~> 0.3"},
      {:credo, "~> 1.6", only: :dev, runtime: false},
      {:dart_sass, "~> 0.5", runtime: @runtimes},
      {:dialyxir, "~> 1.2", only: :dev, runtime: false},
      {:esbuild, "~> 0.5", runtime: @runtimes},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false},
      {:floki, "~> 0.34"},
      {:jason, "~> 1.5.0-alpha.1", override: true},
      {:jason_native, "~> 0.1.0"},
      {:phoenix, "~> 1.7.0-rc.2", override: true, runtime: false},
      {:phoenix_html, "~> 3.2"},
      {:phoenix_live_view, "~> 0.18.11", override: true, runtime: false},
      {:plug_cowboy, "~> 2.6"}
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
