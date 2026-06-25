defmodule PhoenixAssetPipeline.Mix.Assets do
  @moduledoc false

  @default_profiles [
    css: :css,
    images: :images,
    install: :install,
    js: :js,
    svg: :svg
  ]

  def run(:build) do
    Mix.Task.run("compile")
    bun(:install)
    bun(:css)
    bun(:images, ["--clean"])
    bun(:js)
    bun(:svg)
    manifest()
  end

  def run(:deploy) do
    Mix.Task.run("compile")
    bun(:install, ["--frozen-lockfile", "--production"])
    bun(:css)
    bun(:images)
    bun(:js, ["--drop=console", "--drop=debugger", "--production"])
    bun(:svg)
    manifest()
  end

  defp bun(key, extra_args \\ []) do
    Application.ensure_all_started(:bun)
    profile = profile(key)

    case Bun.install_and_run(profile, extra_args) do
      0 -> :ok
      status -> Mix.raise("bun #{profile} #{Enum.join(extra_args, " ")} exited with #{status}")
    end
  end

  defp manifest do
    Mix.Task.reenable("phoenix_asset_pipeline.manifest")
    Mix.Task.run("phoenix_asset_pipeline.manifest")
  end

  defp profile(key) do
    @default_profiles
    |> Keyword.merge(Application.get_env(:phoenix_asset_pipeline, :bun_profiles, []))
    |> Keyword.fetch!(key)
  end
end
