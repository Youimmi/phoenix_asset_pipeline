defmodule PhoenixAssetPipeline.MixProject do
  use Mix.Project

  @description "Asset pipeline for Phoenix app"
  @dev_opts [only: :dev, runtime: false]
  @source_url "https://github.com/Youimmi/phoenix_asset_pipeline"

  defp package do
    [
      files: ["lib", "LICENSE", "mix.exs", "README.md"],
      maintainers: ["Yuri S."],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  def project do
    [
      aliases: aliases(),
      app: :phoenix_asset_pipeline,
      deps: deps(),
      description: @description,
      dialyzer: [plt_add_apps: [:brotli, :dart_sass, :esbuild, :mix, :tailwind]],
      elixir: "~> 1.13",
      package: package(),
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      version: "1.0.8"
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:brotli, "~> 0.3.2", runtime: false},
      {:credo, "~> 1.7", @dev_opts},
      {:dart_sass, "~> 0.7", runtime: false},
      {:dialyxir, "~> 1.4", @dev_opts},
      {:esbuild, "~> 0.8", runtime: false},
      {:ex_doc, ">= 0.0.0", @dev_opts},
      {:floki, ">= 0.36.2"},
      {:git_hooks, "~> 0.8.0-pre0", @dev_opts},
      {:mix_audit, "~> 2.1", @dev_opts},
      {:phoenix_html, "~> 4.1.1"},
      {:plug, "~> 1.16.1"},
      {:sobelow, "~> 0.13", @dev_opts},
      {:styler, "~> 1.0.0", @dev_opts},
      {:tailwind, "~> 0.2", runtime: false}
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
      lint: [
        "deps.get",
        "hex.audit",
        "hex.outdated",
        "deps.audit",
        "deps.unlock --check-unused",
        "compile --warnings-as-errors",
        "format --check-formatted --dry-run",
        "credo -A",
        "dialyzer",
        "sobelow --strict"
      ],
      setup: ["cmd rm -rf _build deps", "deps.get"],
      upgrade: ["cmd rm -rf mix.lock", "setup"]
    ]
  end
end
