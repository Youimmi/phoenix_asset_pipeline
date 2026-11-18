defmodule Mix.Tasks.PhoenixAssetPipeline.Manifest do
  @shortdoc "Generates the PhoenixAssetPipeline manifest"
  @moduledoc """
  Generates the PhoenixAssetPipeline manifest.

  With `precompiled_manifest: true`, this task writes a precompiled manifest
  BEAM module. Otherwise, it writes the cached manifest under the configured
  manifest cache directory.
  Class calls in functions and HEEx resolve the current manifest at runtime.
  Module-scope calls use mappings prepared before Elixir compilation, so
  generating a manifest does not recompile consumer modules.

      mix phoenix_asset_pipeline.manifest
  """
  use Mix.Task

  alias Mix.Tasks.Compile.PhoenixAssetPipeline, as: PhoenixAssetPipelineCompiler

  @impl true
  def run(_) do
    PhoenixAssetPipelineCompiler.with_compiler_disabled(fn ->
      Mix.Task.run("compile")
    end)

    PhoenixAssetPipeline.with_run_lock(fn -> PhoenixAssetPipelineCompiler.save_manifest(PhoenixAssetPipeline.build()) end)
  end
end
