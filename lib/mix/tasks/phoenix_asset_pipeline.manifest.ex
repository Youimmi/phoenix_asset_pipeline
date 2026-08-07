defmodule Mix.Tasks.PhoenixAssetPipeline.Manifest do
  @shortdoc "Generates the PhoenixAssetPipeline manifest"
  @moduledoc """
  Generates the PhoenixAssetPipeline manifest.

  In `:prod`, this task writes a precompiled manifest BEAM module. In `:dev`,
  it writes the cached manifest under the configured manifest cache directory.
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

    PhoenixAssetPipelineCompiler.save_manifest(PhoenixAssetPipeline.build())
  end
end
