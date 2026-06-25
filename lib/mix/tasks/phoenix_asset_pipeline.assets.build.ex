defmodule Mix.Tasks.PhoenixAssetPipeline.Assets.Build do
  @shortdoc "Builds assets and writes the development manifest"
  @moduledoc """
  Builds application assets and writes the development manifest.

      mix phoenix_asset_pipeline.assets.build
  """
  use Mix.Task

  alias PhoenixAssetPipeline.Mix.Assets

  @impl true
  def run(_) do
    Assets.run(:build)
  end
end
