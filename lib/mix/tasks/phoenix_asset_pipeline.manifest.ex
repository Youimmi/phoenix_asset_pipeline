defmodule Mix.Tasks.PhoenixAssetPipeline.Manifest do
  @shortdoc "Generates the PhoenixAssetPipeline manifest"
  @moduledoc """
  Generates the PhoenixAssetPipeline manifest from the configured static directory.

  In `:prod`, this task writes a precompiled manifest BEAM module. In `:dev`,
  it writes the cached manifest under the configured static directory.

      mix phoenix_asset_pipeline.manifest
  """
  use Mix.Task

  alias PhoenixAssetPipeline.Manifest

  @impl true
  def run(_) do
    Mix.Task.run("compile")

    PhoenixAssetPipeline.static_dir()
    |> PhoenixAssetPipeline.build()
    |> save_manifest(Mix.env())
  end

  defp save_manifest(manifest, :prod) do
    manifest
    |> Manifest.save_precompiled!()
    |> log_precompiled()
  end

  defp save_manifest(manifest, :dev) do
    :ok = Manifest.save_cached(manifest)
    log_precompiled(Manifest.cache_path())
  end

  defp save_manifest(_, _), do: :ok

  defp log_precompiled(path) do
    Mix.shell().info("Precompiled #{Path.relative_to_cwd(path)}")
  end
end
