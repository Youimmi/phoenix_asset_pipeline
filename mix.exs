defmodule PhoenixAssetPipeline.MixProject do
  use Mix.Project

  @minimum_otp_release 28
  @source_url "https://github.com/Youimmi/phoenix_asset_pipeline"
  @version "2.0.0"

  if String.to_integer(System.otp_release()) < @minimum_otp_release do
    raise("Requires Erlang/OTP #{@minimum_otp_release} or later")
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  def project do
    [
      aliases: aliases(),
      app: :phoenix_asset_pipeline,
      deps: deps(),
      description: "Asset pipeline for Phoenix applications",
      docs: docs(),
      elixir: "~> 1.18",
      elixirc_options: [
        warnings_as_errors: true
      ],
      package: package(),
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      version: @version
    ]
  end

  defp aliases do
    [
      format: [
        "format",
        "cmd cargo fmt --manifest-path native/phoenix_asset_pipeline/Cargo.toml"
      ],
      precommit: [
        "hex.audit",
        "hex.outdated",
        "deps.unlock --check-unused",
        "compile --warnings-as-errors",
        "credo --strict",
        "cmd cargo fmt --all -- --check",
        "format --check-formatted --dry-run",
        "deps.unlock --unused",
        "format",
        "test"
      ],
      setup: [
        "deps.get",
        "compile"
      ],
      upgrade: [
        "cmd rm -rf Cargo.lock target",
        "cmd rm -rf _build deps mix.lock",
        "deps.get",
        "compile --force",
        "format"
      ]
    ]
  end

  defp deps do
    [
      {:any_ascii, "~> 0.3"},
      {:bun, "~> 2.0", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:file_system, "~> 1.1"},
      {:mime, "~> 2.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:plug, "~> 1.20"},
      {:rustler, "~> 0.38", runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      exclude_patterns: ["native/phoenix_asset_pipeline/target"],
      extras: ["CHANGELOG.md", "LICENSE", "README.md"],
      main: "readme",
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp package do
    [
      files: [
        "Cargo.lock",
        "Cargo.toml",
        "CHANGELOG.md",
        "LICENSE",
        "README.md",
        "lib",
        "mix.exs",
        "native",
        "priv/scripts"
      ],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Youimmi" => "https://youimmi.com"
      },
      maintainers: ["Yuri S."]
    ]
  end
end
