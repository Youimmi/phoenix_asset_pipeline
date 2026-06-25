defmodule Mix.Tasks.PhoenixAssetPipeline.Assets.Deploy do
  @shortdoc "Builds production assets and writes the production manifest"
  @moduledoc """
  Builds production assets and writes the production manifest.

      mix phoenix_asset_pipeline.assets.deploy
  """
  use Mix.Task

  alias PhoenixAssetPipeline.Mix.Assets

  @impl true
  def run(_) do
    Assets.run(:deploy)
  end
end
