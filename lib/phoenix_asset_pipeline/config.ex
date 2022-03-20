defmodule PhoenixAssetPipeline.Config do
  @moduledoc false

  import PhoenixAssetPipeline.Utils, only: [normalize: 1]

  @assets_path Application.compile_env(:phoenix_asset_pipeline, :assets_path, "assets")

  def assets_path, do: normalize(@assets_path)
  def css_path, do: Path.join(assets_path(), "css")
  def img_path, do: Path.join(assets_path(), "img")
  def js_path, do: Path.join(assets_path(), "js")
end
